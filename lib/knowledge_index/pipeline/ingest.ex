defmodule KnowledgeIndex.Pipeline.Ingest do
  use Oban.Worker, queue: :ingest, max_attempts: 3

  alias KnowledgeIndex.{Repo, LLM}
  alias KnowledgeIndex.Schema.{RawSource, WikiPage}

  import Ecto.Query
  require Logger

  @moduledoc """
  Ingests a raw PM artifact into the customer wiki with structured storage.

  No LLM compilation at upload time — just store, structure, and embed.
  Lazy enrichment (Summary, Key Insights, Themes) happens on first retrieval
  via Pipeline.Enrich using Claude Haiku (fast, cheap).

  Flow:
    1. Read the raw source
    2. Parse markdown sections + extract basic entities (regex, no LLM)
    3. Create ONE wiki page with structured template
    4. Generate an embedding for semantic search (Voyage API, fast)
    5. Update the index + append to the log
  """

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id, "workspace_id" => workspace_id}}) do
    with {:ok, source} <- fetch_source(source_id),
         {:ok, wiki_page} <- create_wiki_page_from_source(workspace_id, source),
         {:ok, _} <- embed_page(wiki_page),
         {:ok, _} <- mark_ingested(source, [wiki_page.slug]),
         {:ok, _} <- KnowledgeIndex.Index.rebuild(workspace_id),
         {:ok, _} <- KnowledgeIndex.Log.append(workspace_id, :ingest, source.title, %{
           source_id: source_id,
           wiki_page_slug: wiki_page.slug
         }) do
      broadcast_wiki_update(workspace_id, [wiki_page.slug])
      :ok
    else
      {:error, reason} ->
        Logger.error("[Ingest] Failed for source #{source_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Wiki page creation — no LLM, just structured storage
  # ──────────────────────────────────────────────────────────────────────────

  defp create_wiki_page_from_source(workspace_id, source) do
    slug = generate_slug(source)

    # Parse sections from markdown headers (no LLM needed)
    sections = parse_markdown_sections(source.content)

    # Extract basic entities from title and headers (regex, no LLM)
    entities = extract_entities_from_headers(source.title, sections)

    content = build_wiki_page_content(source, sections, entities)
    summary = generate_summary(source)

    attrs = %{
      "workspace_id" => workspace_id,
      "title" => source.title,
      "slug" => slug,
      "page_type" => "source_summary",
      "content" => content,
      "summary" => summary,
      "source_count" => 1,
      "outbound_links" => [],
      "metadata" => %{
        "source_type" => source.source_type,
        "word_count" => length(String.split(source.content)),
        "uploaded_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "has_cached_insights" => false
      }
    }

    %WikiPage{}
    |> WikiPage.changeset(attrs)
    |> Repo.insert(on_conflict: {:replace, [:content, :summary, :metadata, :version]},
                   conflict_target: [:workspace_id, :slug])
    |> case do
      {:ok, page} ->
        Logger.info("[Ingest] Created wiki page #{slug} for source #{source.id} (#{source.title})")
        {:ok, page}
      {:error, changeset} ->
        Logger.error("[Ingest] Failed to create page #{slug}: #{inspect(changeset.errors)}")
        {:error, {:page_create_failed, changeset.errors}}
    end
  end

  defp build_wiki_page_content(source, sections, entities) do
    """
    # #{source.title}

    **Type:** #{source.source_type}
    **Uploaded:** #{DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d")}
    **Word count:** #{length(String.split(source.content))}

    ## Summary
    _To be generated on first retrieval_

    ## Key Entities
    #{format_entities(entities)}

    ## Key Insights
    _To be generated on first retrieval_

    ## Themes
    _To be generated on first retrieval_

    ## Sections
    #{format_sections(sections)}

    ## Raw Content
    #{String.slice(source.content, 0, 12_000)}
    """
  end

  defp parse_markdown_sections(content) do
    content
    |> String.split("\n")
    |> Enum.filter(&String.match?(&1, ~r/^#{1,3}\s/))
    |> Enum.map(fn line ->
      level = line |> String.graphemes() |> Enum.take_while(&(&1 == "#")) |> length()
      title = String.replace(line, ~r/^#+\s*/, "")
      %{level: level, title: title}
    end)
  end

  defp extract_entities_from_headers(title, sections) do
    all_text = [title | Enum.map(sections, & &1.title)]
    |> Enum.join(" ")

    entities = []

    # Names (capitalized word pairs)
    names = Regex.scan(~r/[A-Z][a-z]+ [A-Z][a-z]+/, all_text) |> List.flatten() |> Enum.uniq()
    entities = entities ++ Enum.map(names, &%{type: "person", name: &1})

    # Companies (common patterns)
    companies = Regex.scan(~r/(?:at|from|for|with)\s+([A-Z][a-zA-Z]+(?:\s[A-Z][a-zA-Z]+)?)/, all_text)
    |> Enum.map(&List.last/1) |> Enum.uniq()
    entities = entities ++ Enum.map(companies, &%{type: "company", name: &1})

    entities
  end

  defp format_entities([]), do: "_None detected — will be enriched on first retrieval_"
  defp format_entities(entities) do
    entities
    |> Enum.map(fn %{type: type, name: name} -> "- **#{name}** (#{type})" end)
    |> Enum.join("\n")
  end

  defp format_sections([]), do: "_No markdown headers found_"
  defp format_sections(sections) do
    sections
    |> Enum.map(fn %{level: level, title: title} ->
      indent = String.duplicate("  ", level - 1)
      "#{indent}- #{title}"
    end)
    |> Enum.join("\n")
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Summary extraction — no LLM, just first meaningful line
  # ──────────────────────────────────────────────────────────────────────────

  defp generate_summary(source) do
    lines = source.content
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(fn line ->
        line == "" or String.starts_with?(line, "#") or String.starts_with?(line, "---")
      end)

    summary = case lines do
      [first | _] ->
        first
        |> String.replace(~r/\*\*([^*]+)\*\*/, "\\1")
        |> String.replace(~r/\*([^*]+)\*/, "\\1")
        |> String.slice(0, 195)
      [] ->
        source.title
    end

    if String.length(summary) > 195, do: String.slice(summary, 0, 192) <> "...", else: summary
  end

  defp generate_slug(source) do
    prefix = case source.source_type do
      "competitive" -> "competitive"
      "transcript" -> "transcript"
      "feedback" -> "feedback"
      "meeting" -> "meeting"
      other -> other
    end

    title_slug = source.title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9\s-]/, "")
      |> String.replace(~r/\s+/, "-")
      |> String.slice(0, 80)
      |> String.trim_trailing("-")

    "#{prefix}-#{title_slug}"
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Embedding (pgvector) — Voyage API call, fast
  # ──────────────────────────────────────────────────────────────────────────

  defp embed_page(wiki_page) do
    text = "#{wiki_page.title}\n\n#{wiki_page.summary}\n\n#{String.slice(wiki_page.content, 0, 2000)}"

    case LLM.embed(text) do
      {:ok, embedding} ->
        wiki_page
        |> WikiPage.changeset(%{embedding: embedding})
        |> Repo.update()
        |> case do
          {:ok, _} ->
            Logger.info("[Ingest] Embedded page #{wiki_page.slug}")
            {:ok, :embedded}
          {:error, changeset} ->
            Logger.warning("[Ingest] Failed to save embedding for #{wiki_page.slug}: #{inspect(changeset.errors)}")
            {:ok, :embed_save_failed}
        end

      {:error, reason} ->
        Logger.warning("[Ingest] Failed to embed page #{wiki_page.slug}: #{inspect(reason)}")
        # Don't fail the whole ingest just because embedding failed
        {:ok, :embed_failed}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────────────────────────────────

  defp fetch_source(source_id) do
    case Repo.get(RawSource, source_id) do
      nil -> {:error, :source_not_found}
      source -> {:ok, source}
    end
  end

  defp mark_ingested(source, pages_touched) do
    source
    |> RawSource.changeset(%{
      ingested_at: DateTime.utc_now(),
      wiki_pages_touched: pages_touched
    })
    |> Repo.update()
  end

  defp broadcast_wiki_update(workspace_id, pages_touched) do
    Phoenix.PubSub.broadcast(
      KnowledgeIndex.PubSub,
      "wiki:#{workspace_id}",
      {:wiki_updated, %{pages: pages_touched, at: DateTime.utc_now()}}
    )
  end
end
