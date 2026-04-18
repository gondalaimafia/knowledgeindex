defmodule KnowledgeIndex.Pipeline.Ingest do
  use Oban.Worker, queue: :ingest, max_attempts: 10

  alias KnowledgeIndex.{Repo, LLM, Wiki, Index, Log}
  alias KnowledgeIndex.Schema.{RawSource, WikiPage}

  import Ecto.Query
  require Logger

  @moduledoc """
  Compiles a raw PM artifact into wiki pages.

  Per Karpathy's LLM Wiki pattern:
    1. LLM reads the raw source
    2. Extracts key entities, concepts, decisions, outcomes
    3. Integrates into existing wiki — updating pages, noting contradictions
    4. A single source may touch 10-15 wiki pages
    5. Updates the index
    6. Appends to the log

  Per Alex's architecture:
    - Sovereign: all pages belong to the workspace, never leave it
    - Structured: entities have relationships, not just embeddings
    - MCP-native: updates broadcast to connected MCP clients in real-time
  """

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"source_id" => source_id, "workspace_id" => workspace_id}}) do
    with {:ok, source} <- fetch_source(source_id),
         {:ok, existing_index} <- Wiki.load_index(workspace_id),
         {:ok, compilation} <- compile(source, existing_index),
         {:ok, pages_touched} <- apply_compilation(workspace_id, compilation),
         {:ok, _} <- mark_ingested(source, pages_touched),
         {:ok, _} <- Log.append(workspace_id, :ingest, source.title, %{
           source_id: source_id,
           pages_touched: pages_touched
         }) do
      broadcast_wiki_update(workspace_id, pages_touched)
      # Defer index rebuild — runs async so pages are visible immediately
      schedule_index_rebuild(workspace_id)
      :ok
    else
      {:error, reason} ->
        Logger.error("[Ingest] Failed for source #{source_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp schedule_index_rebuild(workspace_id) do
    # Debounce: schedule rebuild 5 seconds out so multiple ingests batch into one rebuild
    %{"workspace_id" => workspace_id}
    |> KnowledgeIndex.Pipeline.IndexRebuild.new(
      queue: :index_rebuild,
      unique: [period: 10, keys: [:workspace_id]]
    )
    |> Oban.insert()
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Compilation
  # ──────────────────────────────────────────────────────────────────────────

  defp compile(source, existing_index) do
    prompt = build_ingest_prompt(source, existing_index)
    Logger.info("[Ingest] Calling LLM for source #{source.id} (#{source.title})...")

    case LLM.complete(prompt, system: ingest_system_prompt(), max_tokens: 16384) do
      {:ok, response} ->
        Logger.info("[Ingest] LLM responded for source #{source.id}, parsing (#{String.length(response)} chars)...")
        case parse_compilation(response) do
          {:ok, _} = result -> result
          {:error, :invalid_llm_response} = err ->
            Logger.error("[Ingest] Parse failed for source #{source.id}. First 500 chars: #{String.slice(response, 0, 500)}")
            Logger.error("[Ingest] Last 200 chars: #{String.slice(response, -200, 200)}")
            err
        end
      {:error, reason} = err ->
        Logger.error("[Ingest] LLM failed for source #{source.id}: #{inspect(reason)}")
        err
    end
  end

  defp build_ingest_prompt(source, existing_index) do
    """
    You are maintaining a PM knowledge wiki for a product team.

    ## New source to ingest

    Type: #{source.source_type}
    Title: #{source.title}
    Content:
    #{source.content}

    ## Current wiki index

    #{format_index(existing_index)}

    ## Your task

    1. Read the source carefully.
    2. Identify all entities (features, metrics, users, competitors, decisions).
    3. For each entity, determine if a wiki page already exists (check the index).
       - If yes: provide updated content that integrates the new information.
       - If no: create a new entity page.
    4. Identify any concept pages that need updating (themes, patterns, strategies).
    5. Write a source_summary page for this artifact.
    6. Flag any contradictions with existing pages.
    7. If this source contains outcome data (metric results, experiment conclusions),
       create or update an outcome page.

    ## Output format

    Return a JSON object with these exact keys. All fields marked REQUIRED must be present.

    {
      "new_pages": [
        {
          "slug": "feature-smart-notifications",   // REQUIRED. Lowercase, hyphenated, no spaces.
          "title": "Smart Notifications",            // REQUIRED. Human-readable title.
          "page_type": "entity",                     // REQUIRED. One of: entity, concept, decision, synthesis, source_summary, outcome
          "content": "## Smart Notifications\\n\\nFull markdown content...",  // REQUIRED. Full markdown body.
          "summary": "Push notification feature targeting re-engagement",     // REQUIRED. Under 200 characters.
          "outbound_links": ["metric-dau-d7", "user-segment-dormant"]         // Slugs of related pages.
        }
      ],
      "updated_pages": [
        {
          "slug": "metric-dau-d7",                   // REQUIRED. Must match an existing page slug from the index.
          "content": "Updated full content...",       // REQUIRED. Complete updated page content (not a diff).
          "summary": "DAU D7 retention metric — currently 34%, target 42%"  // REQUIRED. Under 200 characters.
        }
      ],
      "contradictions": [
        {
          "page_slug": "decision-push-notifications-opt-in",  // REQUIRED. Slug of the page with the conflicting claim.
          "claim": "Source says notifications are opt-out by default",
          "existing_claim": "Wiki says notifications require explicit opt-in"
        }
      ]
    }

    CRITICAL RULES:
    1. Return ONLY valid JSON. No markdown fences (no ```), no commentary, no text before or after the JSON object.
    2. Keep each page's content CONCISE — 300-800 words max per page. Focus on key facts, decisions, and insights. Do not reproduce the source verbatim.
    3. Create 3-6 pages per source, not more. Quality over quantity.
    4. The entire response must be valid JSON that can be parsed in one pass.
    """
  end

  defp ingest_system_prompt do
    """
    You are a disciplined wiki maintainer for a product team's Knowledge Index.
    Your job is to compile raw PM artifacts into structured, interlinked wiki pages.

    Rules:
    - The wiki is a persistent, compounding artifact. Every page should be richer after ingest.
    - Never delete existing content — integrate and extend.
    - Cross-references are valuable. Link entities to related concepts, decisions, and outcomes.
    - Flag contradictions explicitly — do not silently overwrite conflicting claims.
    - Outcome data is critical — always create or update outcome pages when metrics appear.
    - The human reads the wiki. The LLM maintains it. Write for humans.
    - Keep summaries under 200 characters.
    - Keep page content CONCISE: 300-800 words. Synthesize, don't reproduce.
    - Return raw JSON only. Never wrap in markdown code fences.
    """
  end

  defp parse_compilation(response) do
    case Jason.decode(response) do
      {:ok, data} when is_map(data) ->
        {:ok, %{
          new_pages: Map.get(data, "new_pages", []),
          updated_pages: Map.get(data, "updated_pages", []),
          contradictions: Map.get(data, "contradictions", [])
        }}

      _ ->
        # LLM returned non-JSON — attempt to extract JSON block (no recursion)
        case extract_json(response) do
          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, data} when is_map(data) ->
                {:ok, %{
                  new_pages: Map.get(data, "new_pages", []),
                  updated_pages: Map.get(data, "updated_pages", []),
                  contradictions: Map.get(data, "contradictions", [])
                }}

              _ ->
                {:error, :invalid_llm_response}
            end

          :error ->
            {:error, :invalid_llm_response}
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Apply compilation to database
  # ──────────────────────────────────────────────────────────────────────────

  defp apply_compilation(workspace_id, %{new_pages: new, updated_pages: updated, contradictions: contradictions}) do
    # DB transaction: create/update pages and flag contradictions (no HTTP calls here)
    result =
      Repo.transaction(fn ->
        pages_touched =
          Enum.concat(
            Enum.map(new, &create_page(workspace_id, &1)),
            Enum.map(updated, &update_page(workspace_id, &1))
          )
          |> Enum.reject(&is_nil/1)

        Enum.each(contradictions, &flag_contradiction(workspace_id, &1))

        pages_touched
      end)

    # Post-transaction work: embed pages and rebuild inbound links (no DB transaction held)
    case result do
      {:ok, pages_touched} ->
        embed_pages(workspace_id, pages_touched)
        rebuild_inbound_links(workspace_id)
        {:ok, pages_touched}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_page(workspace_id, attrs) do
    attrs
    |> Map.put("workspace_id", workspace_id)
    |> Map.put_new("source_count", 1)
    |> validate_page_attrs()
    |> case do
      :error ->
        Logger.warning("[Ingest] Invalid page attrs: #{inspect(attrs)}")
        nil

      validated_attrs ->
        %WikiPage{}
        |> WikiPage.changeset(validated_attrs)
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:workspace_id, :slug])
        |> case do
          {:ok, %{id: nil}} ->
            Logger.info("[Ingest] Page #{attrs["slug"]} already exists, skipping create")
            attrs["slug"]
          {:ok, page} ->
            page.slug
          {:error, changeset} ->
            Logger.warning("[Ingest] Failed to create page #{attrs["slug"]}: #{inspect(changeset.errors)}")
            nil
        end
    end
  end

  defp update_page(workspace_id, %{"slug" => slug} = attrs) do
    case Repo.get_by(WikiPage, workspace_id: workspace_id, slug: slug) do
      nil ->
        Logger.warning("[Ingest] Page #{slug} not found for update, creating instead")
        create_page(workspace_id, attrs)

      existing ->
        existing
        |> WikiPage.changeset(
          attrs
          |> Map.put("version", existing.version + 1)
          |> Map.put("source_count", existing.source_count + 1)
        )
        |> Repo.update()
        |> case do
          {:ok, page} -> page.slug
          {:error, changeset} ->
            Logger.warning("[Ingest] Failed to update page #{slug}: #{inspect(changeset.errors)}")
            nil
        end
    end
  end

  defp flag_contradiction(workspace_id, %{"page_slug" => slug} = contradiction) do
    case Repo.get_by(WikiPage, workspace_id: workspace_id, slug: slug) do
      nil -> :ok
      page ->
        updated = [contradiction["claim"] | page.contradictions] |> Enum.uniq() |> Enum.take(20)

        page
        |> WikiPage.changeset(%{contradictions: updated})
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, changeset} ->
            Logger.warning("[Ingest] Failed to flag contradiction on #{slug}: #{inspect(changeset.errors)}")
        end
    end
  end

  defp flag_contradiction(_workspace_id, invalid) do
    Logger.warning("[Ingest] Skipping malformed contradiction: #{inspect(invalid)}")
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Embedding (pgvector) — runs outside DB transactions
  # ──────────────────────────────────────────────────────────────────────────

  defp embed_pages(workspace_id, slugs) do
    pages =
      Repo.all(
        from p in WikiPage,
          where: p.workspace_id == ^workspace_id and p.slug in ^slugs
      )
      |> Enum.reject(&is_nil(&1.id))

    if pages == [] do
      :ok
    else
      # Batch embed: one Voyage API call for all pages instead of N sequential calls
      texts = Enum.map(pages, fn page ->
        "#{page.title}\n\n#{page.summary}\n\n#{String.slice(page.content, 0, 2000)}"
      end)

      case LLM.embed_batch(texts) do
        {:ok, embeddings} ->
          # Save embeddings concurrently
          pages
          |> Enum.zip(embeddings)
          |> Task.async_stream(
            fn {page, embedding} ->
              page
              |> WikiPage.changeset(%{embedding: embedding})
              |> Repo.update()
              |> case do
                {:ok, _} -> :ok
                {:error, changeset} ->
                  Logger.warning("[Ingest] Failed to save embedding for #{page.slug}: #{inspect(changeset.errors)}")
              end
            end,
            max_concurrency: 10,
            timeout: 30_000
          )
          |> Stream.run()

        {:error, reason} ->
          Logger.warning("[Ingest] Batch embed failed: #{inspect(reason)}, falling back to sequential")
          Enum.each(pages, &embed_page_fallback/1)
      end
    end
  end

  defp embed_page_fallback(%WikiPage{} = page) do
    text = "#{page.title}\n\n#{page.summary}\n\n#{String.slice(page.content, 0, 2000)}"

    case LLM.embed(text) do
      {:ok, embedding} ->
        page
        |> WikiPage.changeset(%{embedding: embedding})
        |> Repo.update()
        |> case do
          {:ok, _} -> :ok
          {:error, changeset} ->
            Logger.warning("[Ingest] Failed to save embedding for #{page.slug}: #{inspect(changeset.errors)}")
        end

      {:error, reason} ->
        Logger.warning("[Ingest] Failed to embed page #{page.slug}: #{inspect(reason)}")
    end
  end

  defp validate_page_attrs(%{"slug" => slug, "title" => title, "page_type" => _, "content" => _} = attrs)
       when is_binary(slug) and is_binary(title) do
    attrs
  end

  defp validate_page_attrs(_), do: :error

  # ──────────────────────────────────────────────────────────────────────────
  # Inbound links — compute the reverse of outbound_links for navigation
  # ──────────────────────────────────────────────────────────────────────────

  defp rebuild_inbound_links(workspace_id) do
    pages =
      Repo.all(
        from p in WikiPage,
          where: p.workspace_id == ^workspace_id,
          select: {p.slug, p.outbound_links}
      )

    # Build reverse index: for each outbound link, record who links to it
    inbound_map =
      Enum.reduce(pages, %{}, fn {slug, outbound_links}, acc ->
        Enum.reduce(outbound_links, acc, fn target, inner_acc ->
          Map.update(inner_acc, target, [slug], &[slug | &1])
        end)
      end)

    # Update each page's inbound_links
    Enum.each(inbound_map, fn {slug, inbound} ->
      case Repo.get_by(WikiPage, workspace_id: workspace_id, slug: slug) do
        nil -> :ok
        page ->
          inbound = Enum.uniq(inbound)

          if inbound != page.inbound_links do
            page
            |> WikiPage.changeset(%{inbound_links: inbound})
            |> Repo.update()
          end
      end
    end)
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

  defp format_index(index_entries) do
    index_entries
    |> Enum.group_by(& &1.category)
    |> Enum.map(fn {category, entries} ->
      items = Enum.map(entries, &"- [[#{&1.wiki_page_slug}]] #{&1.title} — #{&1.summary}")
      "### #{String.capitalize(category)}\n#{Enum.join(items, "\n")}"
    end)
    |> Enum.join("\n\n")
  end

  defp extract_json(text) do
    # Strip markdown code fences if present
    cleaned = text
      |> String.replace(~r/^```(?:json)?\s*\n?/m, "")
      |> String.replace(~r/\n?```\s*$/m, "")
      |> String.trim()

    # Try the cleaned text first (might be pure JSON after fence removal)
    case Jason.decode(cleaned) do
      {:ok, data} when is_map(data) -> {:ok, cleaned}
      _ ->
        # Find the outermost JSON object by matching balanced braces
        case find_balanced_json(cleaned) do
          nil -> :error
          json -> {:ok, json}
        end
    end
  end

  defp find_balanced_json(text) do
    case :binary.match(text, "{") do
      {start, _} ->
        text
        |> String.slice(start..-1//1)
        |> scan_balanced_braces(0, 0)
      :nomatch -> nil
    end
  end

  defp scan_balanced_braces(text, pos, depth) do
    cond do
      pos >= String.length(text) -> nil
      String.at(text, pos) == "{" -> scan_balanced_braces(text, pos + 1, depth + 1)
      String.at(text, pos) == "}" ->
        if depth == 1 do
          String.slice(text, 0..pos)
        else
          scan_balanced_braces(text, pos + 1, depth - 1)
        end
      true -> scan_balanced_braces(text, pos + 1, depth)
    end
  end

  defp broadcast_wiki_update(workspace_id, pages_touched) do
    Phoenix.PubSub.broadcast(
      KnowledgeIndex.PubSub,
      "wiki:#{workspace_id}",
      {:wiki_updated, %{pages: pages_touched, at: DateTime.utc_now()}}
    )
  end
end
