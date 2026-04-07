defmodule KnowledgeIndex.Pipeline.Ingest do
  use Oban.Worker, queue: :ingest, max_attempts: 3

  alias KnowledgeIndex.{Repo, LLM, Wiki, Index, Log}
  alias KnowledgeIndex.Schema.{RawSource, WikiPage}

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
         {:ok, _} <- Index.rebuild(workspace_id),
         {:ok, _} <- Log.append(workspace_id, :ingest, source.title, %{
           source_id: source_id,
           pages_touched: pages_touched
         }) do
      broadcast_wiki_update(workspace_id, pages_touched)
      :ok
    else
      {:error, reason} ->
        Logger.error("[Ingest] Failed for source #{source_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Compilation
  # ──────────────────────────────────────────────────────────────────────────

  defp compile(source, existing_index) do
    prompt = build_ingest_prompt(source, existing_index)

    case LLM.complete(prompt, system: ingest_system_prompt()) do
      {:ok, response} -> parse_compilation(response)
      {:error, _} = err -> err
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

    Return a JSON object:
    {
      "new_pages": [
        {
          "slug": "feature-smart-notifications",
          "title": "Smart Notifications",
          "page_type": "entity",
          "content": "## Smart Notifications\\n\\nFull markdown content...",
          "summary": "Push notification feature targeting re-engagement",
          "outbound_links": ["metric-dau-d7", "user-segment-dormant"]
        }
      ],
      "updated_pages": [
        {
          "slug": "metric-dau-d7",
          "content": "Updated full content integrating new data from this source...",
          "summary": "DAU D7 retention metric — currently 34%, target 42%"
        }
      ],
      "contradictions": [
        {
          "page_slug": "decision-push-notifications-opt-in",
          "claim": "Source says notifications are opt-out by default",
          "existing_claim": "Wiki says notifications require explicit opt-in"
        }
      ]
    }

    Return only valid JSON. No markdown wrapper.
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
    """
  end

  defp parse_compilation(response) do
    case Jason.decode(response) do
      {:ok, data} ->
        {:ok, %{
          new_pages: Map.get(data, "new_pages", []),
          updated_pages: Map.get(data, "updated_pages", []),
          contradictions: Map.get(data, "contradictions", [])
        }}
      {:error, _} ->
        # LLM returned non-JSON — attempt to extract JSON block
        case extract_json(response) do
          {:ok, json} -> parse_compilation(json)
          :error -> {:error, :invalid_llm_response}
        end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Apply compilation to database
  # ──────────────────────────────────────────────────────────────────────────

  defp apply_compilation(workspace_id, %{new_pages: new, updated_pages: updated, contradictions: contradictions}) do
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
  end

  defp create_page(workspace_id, attrs) do
    attrs
    |> Map.put("workspace_id", workspace_id)
    |> then(&WikiPage.changeset(%WikiPage{}, &1))
    |> then(fn changeset ->
      case Repo.insert(changeset, on_conflict: :nothing) do
        {:ok, page} ->
          embed_page(page)
          page.slug
        {:error, _} ->
          Logger.warning("[Ingest] Page #{attrs["slug"]} already exists, skipping create")
          nil
      end
    end)
  end

  defp update_page(workspace_id, %{"slug" => slug} = attrs) do
    case Repo.get_by(WikiPage, workspace_id: workspace_id, slug: slug) do
      nil ->
        Logger.warning("[Ingest] Page #{slug} not found for update, creating instead")
        create_page(workspace_id, attrs)

      existing ->
        existing
        |> WikiPage.changeset(Map.put(attrs, "version", existing.version + 1))
        |> Repo.update!()
        |> tap(&embed_page/1)
        |> Map.get(:slug)
    end
  end

  defp flag_contradiction(workspace_id, %{"page_slug" => slug} = contradiction) do
    case Repo.get_by(WikiPage, workspace_id: workspace_id, slug: slug) do
      nil -> :ok
      page ->
        page
        |> WikiPage.changeset(%{contradictions: [contradiction["claim"] | page.contradictions]})
        |> Repo.update!()
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Embedding (pgvector)
  # ──────────────────────────────────────────────────────────────────────────

  defp embed_page(%WikiPage{} = page) do
    text = "#{page.title}\n\n#{page.summary}\n\n#{String.slice(page.content, 0, 2000)}"

    case LLM.embed(text) do
      {:ok, embedding} ->
        page
        |> WikiPage.changeset(%{embedding: embedding})
        |> Repo.update!()
      {:error, reason} ->
        Logger.warning("[Ingest] Failed to embed page #{page.slug}: #{inspect(reason)}")
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
    case Regex.run(~r/\{[\s\S]*\}/m, text) do
      [json | _] -> {:ok, json}
      nil -> :error
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
