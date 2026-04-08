defmodule KnowledgeIndexWeb.KIController do
  use Phoenix.Controller, formats: [:json]

  alias KnowledgeIndex.{Pipeline, Wiki, Repo}
  alias KnowledgeIndex.Schema.RawSource

  def health(conn, _params) do
    json(conn, %{status: "ok", service: "knowledge-index"})
  end

  def query(conn, %{"workspace_id" => ws, "query" => query} = params) do
    file_answer = Map.get(params, "file_answer", true)

    case Pipeline.Query.run(ws, query, file_answer: file_answer) do
      {:ok, answer} ->
        json(conn, %{answer: answer})
      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
  end

  def ingest(conn, %{"workspace_id" => ws, "source_type" => type, "title" => title, "content" => content} = params) do
    attrs = %{
      workspace_id: ws,
      source_type: type,
      title: title,
      content: content,
      metadata: Map.get(params, "metadata", %{})
    }

    case Repo.insert(RawSource.changeset(%RawSource{}, attrs)) do
      {:ok, source} ->
        Oban.insert(Pipeline.Ingest.new(%{"source_id" => source.id, "workspace_id" => ws}))
        json(conn, %{message: "Queued for ingestion", source_id: source.id})
      {:error, changeset} ->
        conn |> put_status(400) |> json(%{error: inspect(changeset.errors)})
    end
  end

  def search(conn, %{"workspace_id" => ws, "query" => query} = params) do
    page_type = Map.get(params, "page_type")
    limit =
      case Integer.parse(Map.get(params, "limit", "10")) do
        {n, _} -> n
        :error -> 10
      end

    # Simple search via index for now
    {:ok, index} = Wiki.load_index(ws)

    results =
      index
      |> Enum.filter(fn entry ->
        query_lower = String.downcase(query)
        combined = "#{String.downcase(entry.title)} #{String.downcase(entry.summary)}"
        String.contains?(combined, query_lower) and
          (is_nil(page_type) or entry.page_type == page_type)
      end)
      |> Enum.take(limit)
      |> Enum.map(fn entry ->
        %{slug: entry.wiki_page_slug, title: entry.title, page_type: entry.page_type, summary: entry.summary}
      end)

    json(conn, results)
  end

  def index(conn, %{"workspace_id" => ws} = params) do
    {:ok, entries} = Wiki.load_index(ws)

    entries =
      case Map.get(params, "category") do
        nil -> entries
        cat -> Enum.filter(entries, &(&1.category == cat))
      end

    grouped =
      entries
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {cat, items} ->
        %{category: cat, pages: Enum.map(items, &%{slug: &1.wiki_page_slug, title: &1.title, summary: &1.summary})}
      end)

    json(conn, grouped)
  end

  def lint(conn, %{"workspace_id" => ws}) do
    Oban.insert(Pipeline.Lint.new(%{"workspace_id" => ws}))
    json(conn, %{message: "Lint pass queued"})
  end

  def stats(conn, %{"workspace_id" => ws}) do
    import Ecto.Query

    page_count = Repo.aggregate(
      from(p in KnowledgeIndex.Schema.WikiPage, where: p.workspace_id == ^ws),
      :count
    )

    source_count = Repo.aggregate(
      from(s in RawSource, where: s.workspace_id == ^ws),
      :count
    )

    stale_count = Repo.aggregate(
      from(p in KnowledgeIndex.Schema.WikiPage, where: p.workspace_id == ^ws and p.stale == true),
      :count
    )

    json(conn, %{
      page_count: page_count,
      source_count: source_count,
      stale_count: stale_count
    })
  end

  def logs(conn, %{"workspace_id" => ws} = params) do
    import Ecto.Query

    limit =
      case Integer.parse(Map.get(params, "limit", "50")) do
        {n, _} -> n
        :error -> 50
      end

    logs =
      from(l in KnowledgeIndex.Schema.LogEntry,
        where: l.workspace_id == ^ws,
        order_by: [desc: l.inserted_at],
        limit: ^limit
      )
      |> Repo.all()
      |> Enum.map(fn l ->
        %{
          id: l.id,
          operation: l.operation,
          label: l.label,
          detail: l.detail,
          inserted_at: l.inserted_at
        }
      end)

    json(conn, logs)
  end
end
