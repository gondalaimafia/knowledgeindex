defmodule KnowledgeIndex.Pipeline.Query do
  alias KnowledgeIndex.{Repo, Wiki, LLM, Log}
  alias KnowledgeIndex.Schema.{WikiPage, IndexEntry}

  import Ecto.Query
  import Pgvector.Ecto.Query

  @moduledoc """
  Query the Knowledge Index.

  Per Karpathy: the LLM reads the index first to find relevant pages,
  then drills into them. Good answers get filed back as wiki pages —
  explorations compound in the knowledge base just like ingested sources.

  Two retrieval strategies:
  1. Index-first (structural): read index → find relevant page slugs → fetch full pages
  2. Semantic (vector): embed query → cosine similarity over wiki embeddings

  For PM queries, structural often wins because the questions are specific:
  "What did we decide about notifications?" → index scan → decision pages
  "What's our retention trend?" → index scan → outcome pages for retention
  """

  @max_index_pages 10
  @max_semantic_pages 5

  def run(workspace_id, query_text, opts \\ []) do
    file_answer = Keyword.get(opts, :file_answer, true)

    with {:ok, index} <- Wiki.load_index(workspace_id),
         {:ok, relevant_slugs} <- find_relevant_pages(workspace_id, query_text, index),
         {:ok, pages} <- fetch_pages(workspace_id, relevant_slugs),
         {:ok, answer} <- synthesize(query_text, pages),
         {:ok, _} <- maybe_file_answer(workspace_id, query_text, answer, file_answer),
         {:ok, _} <- Log.append(workspace_id, :query, query_text, %{
           pages_consulted: relevant_slugs,
           answer_filed: file_answer
         }) do
      {:ok, answer}
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Page retrieval
  # ──────────────────────────────────────────────────────────────────────────

  defp find_relevant_pages(workspace_id, query_text, index) do
    # Strategy 1: index scan (fast, structural)
    index_slugs = scan_index(query_text, index)

    # Strategy 2: semantic search (embedding similarity)
    semantic_slugs = semantic_search(workspace_id, query_text)

    # Merge and deduplicate, index results first
    all_slugs =
      (index_slugs ++ semantic_slugs)
      |> Enum.uniq()
      |> Enum.take(@max_index_pages + @max_semantic_pages)

    {:ok, all_slugs}
  end

  defp scan_index(query_text, index_entries) do
    query_lower = String.downcase(query_text)
    query_words = String.split(query_lower, ~r/\s+/)

    index_entries
    |> Enum.map(fn entry ->
      combined = "#{String.downcase(entry.title)} #{String.downcase(entry.summary)}"
      score = Enum.count(query_words, &String.contains?(combined, &1))
      {entry.wiki_page_slug, score}
    end)
    |> Enum.filter(fn {_, score} -> score > 0 end)
    |> Enum.sort_by(fn {_, score} -> score end, :desc)
    |> Enum.take(@max_index_pages)
    |> Enum.map(fn {slug, _} -> slug end)
  end

  defp semantic_search(workspace_id, query_text) do
    case LLM.embed(query_text) do
      {:ok, embedding} ->
        Repo.all(
          from p in WikiPage,
            where: p.workspace_id == ^workspace_id,
            where: not is_nil(p.embedding),
            order_by: cosine_distance(p.embedding, ^embedding),
            limit: @max_semantic_pages,
            select: p.slug
        )
      {:error, _} ->
        []
    end
  end

  defp fetch_pages(workspace_id, slugs) do
    pages =
      Repo.all(
        from p in WikiPage,
          where: p.workspace_id == ^workspace_id and p.slug in ^slugs
      )
    {:ok, pages}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Synthesis
  # ──────────────────────────────────────────────────────────────────────────

  defp synthesize(query_text, pages) do
    pages_text =
      pages
      |> Enum.map(fn page -> "## [[#{page.slug}]] #{page.title}\n\n#{page.content}" end)
      |> Enum.join("\n\n---\n\n")

    prompt = """
    Answer the following question using only the wiki pages provided.
    Cite pages using [[slug]] format.
    If the wiki does not contain enough information, say so explicitly.

    Question: #{query_text}

    Wiki pages:
    #{pages_text}
    """

    LLM.complete(prompt, system: query_system_prompt())
  end

  defp query_system_prompt do
    """
    You are answering questions for a product manager using their team's knowledge wiki.
    Be specific and grounded. Cite wiki pages. Do not hallucinate information not in the wiki.
    If information is missing, say what's missing and suggest what source might fill the gap.
    Keep answers focused and actionable.
    """
  end

  # ──────────────────────────────────────────────────────────────────────────
  # File answer back to wiki (answers compound in the knowledge base)
  # ──────────────────────────────────────────────────────────────────────────

  defp maybe_file_answer(_workspace_id, _query, _answer, false), do: {:ok, :skipped}

  defp maybe_file_answer(workspace_id, query_text, answer, true) do
    slug = "query-#{:crypto.hash(:md5, query_text) |> Base.encode16(case: :lower) |> String.slice(0, 8)}"
    title = "Q: #{String.slice(query_text, 0, 80)}"

    attrs = %{
      "workspace_id" => workspace_id,
      "title" => title,
      "slug" => slug,
      "page_type" => "synthesis",
      "content" => "## #{title}\n\n#{answer}",
      "summary" => String.slice(answer, 0, 200)
    }

    %WikiPage{}
    |> WikiPage.changeset(attrs)
    |> Repo.insert(on_conflict: {:replace, [:content, :summary, :version]}, conflict_target: [:workspace_id, :slug])
    |> case do
      {:ok, page} ->
        Log.append(workspace_id, :query, query_text, %{answer_slug: page.slug})
        {:ok, page}
      {:error, _} = err -> err
    end
  end

  # Search wiki pages (used by MCP handler and HTTP search endpoint)
  def search(workspace_id, query_text, opts \\ []) do
    page_type = Keyword.get(opts, :page_type)
    limit = Keyword.get(opts, :limit, 10)

    {:ok, index} = Wiki.load_index(workspace_id)

    results =
      index
      |> Enum.filter(fn entry ->
        query_lower = String.downcase(query_text)
        combined = "#{String.downcase(entry.title)} #{String.downcase(entry.summary)}"
        String.contains?(combined, query_lower) and
          (is_nil(page_type) or entry.page_type == page_type)
      end)
      |> Enum.take(limit)
      |> Enum.map(fn entry ->
        %{slug: entry.wiki_page_slug, title: entry.title, page_type: entry.page_type, summary: entry.summary}
      end)

    {:ok, results}
  end
end
