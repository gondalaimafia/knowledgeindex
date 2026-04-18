defmodule KnowledgeIndex.Pipeline.Enrich do
  alias KnowledgeIndex.{Repo, LLM}
  alias KnowledgeIndex.Schema.WikiPage

  require Logger

  @moduledoc """
  Lazy compilation — fills in Summary, Key Insights, Key Entities, and Themes
  on a wiki page the first time it's retrieved for generation.

  Uses Claude Haiku (fast, cheap) not Sonnet.
  Results are cached on the wiki page for all future retrievals.
  """

  @haiku_model "claude-3-5-haiku-20241022"

  def enrich_if_needed(%WikiPage{} = page) do
    if needs_enrichment?(page) do
      enrich(page)
    else
      {:ok, page}
    end
  end

  defp needs_enrichment?(page) do
    metadata = page.metadata || %{}
    metadata["has_cached_insights"] != true
  end

  defp enrich(page) do
    # Extract raw content (skip the template placeholders)
    raw_content = extract_raw_content(page.content)

    prompt = """
    Analyze this document and extract structured information.

    Document title: #{page.title}
    Document type: #{Map.get(page.metadata || %{}, "source_type", "unknown")}

    Content:
    #{String.slice(raw_content, 0, 8_000)}

    Return a JSON object with exactly these fields:
    {
      "summary": "2 to 3 sentence summary of the key content",
      "key_entities": [
        {"type": "person|company|feature|metric|tool", "name": "Entity Name", "context": "brief context"}
      ],
      "key_insights": [
        "Specific, quotable insight from the document"
      ],
      "themes": ["theme-tag-1", "theme-tag-2"]
    }

    Rules:
    - Summary: max 3 sentences, focus on what's actionable for a product manager
    - Key entities: only entities explicitly mentioned, max 8
    - Key insights: specific facts, numbers, or quotes, max 6
    - Themes: lowercase, hyphenated tags, max 5

    Return only valid JSON.
    """

    case LLM.complete(prompt, model: @haiku_model, max_tokens: 1024) do
      {:ok, response} ->
        # Strip markdown code fences if present
        cleaned = response
          |> String.trim()
          |> String.replace(~r/^```json\s*/, "")
          |> String.replace(~r/\s*```$/, "")

        case Jason.decode(cleaned) do
          {:ok, data} ->
            updated_content = rebuild_content_with_enrichment(page, data)
            updated_metadata = Map.merge(page.metadata || %{}, %{"has_cached_insights" => true})

            page
            |> WikiPage.changeset(%{
              content: updated_content,
              summary: data["summary"] || page.summary,
              metadata: updated_metadata
            })
            |> Repo.update()

          {:error, _} ->
            Logger.warning("[Enrich] Failed to parse LLM response for #{page.slug}")
            {:ok, page}
        end

      {:error, reason} ->
        Logger.warning("[Enrich] LLM call failed for #{page.slug}: #{inspect(reason)}")
        {:ok, page}
    end
  end

  defp extract_raw_content(content) do
    # Get the text after "## Raw Content" header
    case String.split(content, "## Raw Content\n", parts: 2) do
      [_, raw] -> String.trim(raw)
      _ -> content
    end
  end

  defp rebuild_content_with_enrichment(page, data) do
    entities_text =
      (data["key_entities"] || [])
      |> Enum.map(fn e -> "- **#{e["name"]}** (#{e["type"]}) — #{e["context"]}" end)
      |> Enum.join("\n")

    insights_text =
      (data["key_insights"] || [])
      |> Enum.map(fn i -> "- #{i}" end)
      |> Enum.join("\n")

    themes_text =
      (data["themes"] || [])
      |> Enum.join(", ")

    source_type = Map.get(page.metadata || %{}, "source_type", "unknown")
    word_count = Map.get(page.metadata || %{}, "word_count", 0)
    uploaded_at = Map.get(page.metadata || %{}, "uploaded_at", "unknown")

    raw_content = extract_raw_content(page.content)

    """
    # #{page.title}

    **Type:** #{source_type}
    **Uploaded:** #{uploaded_at}
    **Word count:** #{word_count}

    ## Summary
    #{data["summary"] || "No summary available."}

    ## Key Entities
    #{if entities_text == "", do: "None extracted.", else: entities_text}

    ## Key Insights
    #{if insights_text == "", do: "None extracted.", else: insights_text}

    ## Themes
    #{if themes_text == "", do: "None.", else: themes_text}

    ## Raw Content
    #{String.slice(raw_content, 0, 12_000)}
    """
  end
end
