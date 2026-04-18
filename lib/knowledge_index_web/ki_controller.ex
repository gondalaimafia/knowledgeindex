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
    import Ecto.Query

    checksum = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    # Check for duplicate by checksum (same content in same workspace)
    existing_by_checksum = Repo.one(
      from(s in RawSource,
        where: s.workspace_id == ^ws and s.checksum == ^checksum,
        limit: 1
      )
    )

    if existing_by_checksum do
      conn |> put_status(409) |> json(%{
        error: "Duplicate content detected",
        duplicate_of: %{
          id: existing_by_checksum.id,
          title: existing_by_checksum.title,
          source_type: existing_by_checksum.source_type
        },
        message: "A source with identical content already exists: \"#{existing_by_checksum.title}\""
      })
    else
      # Check for duplicate by title (same title in same workspace)
      existing_by_title = Repo.one(
        from(s in RawSource,
          where: s.workspace_id == ^ws and s.title == ^title,
          limit: 1
        )
      )

      if existing_by_title do
        # Title match but different content — warn but allow with flag
        if Map.get(params, "force", false) do
          do_ingest(conn, ws, type, title, content, params)
        else
          conn |> put_status(409) |> json(%{
            error: "Duplicate title detected",
            duplicate_of: %{
              id: existing_by_title.id,
              title: existing_by_title.title,
              source_type: existing_by_title.source_type,
              word_count: length(String.split(existing_by_title.content || ""))
            },
            message: "A source with the same title already exists. Set \"force\": true to upload anyway.",
            new_word_count: length(String.split(content))
          })
        end
      else
        do_ingest(conn, ws, type, title, content, params)
      end
    end
  end

  defp do_ingest(conn, ws, type, title, content, params) do
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
        json(conn, %{message: "Source stored. Wiki page created.", source_id: source.id})
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

  def rebuild_index(conn, %{"workspace_id" => ws}) do
    case KnowledgeIndex.Index.rebuild(ws) do
      {:ok, count} ->
        json(conn, %{message: "Index rebuilt", count: count})
      {:error, reason} ->
        conn |> put_status(500) |> json(%{error: inspect(reason)})
    end
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

  # List all sources for a workspace
  def sources(conn, %{"workspace_id" => ws} = params) do
    import Ecto.Query

    limit =
      case Integer.parse(Map.get(params, "limit", "100")) do
        {n, _} -> n
        :error -> 100
      end

    sources =
      from(s in RawSource,
        where: s.workspace_id == ^ws,
        order_by: [desc: s.inserted_at],
        limit: ^limit
      )
      |> Repo.all()
      |> Enum.map(fn s ->
        %{
          id: s.id,
          title: s.title,
          source_type: s.source_type,
          ingested_at: s.ingested_at,
          wiki_pages_touched: s.wiki_pages_touched,
          word_count: length(String.split(s.content || "")),
          metadata: s.metadata,
          inserted_at: s.inserted_at,
          updated_at: s.updated_at
        }
      end)

    json(conn, sources)
  end

  # Get a single source with content preview
  def source_detail(conn, %{"id" => id}) do
    case Repo.get(RawSource, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Source not found"})
      source ->
        json(conn, %{
          id: source.id,
          title: source.title,
          source_type: source.source_type,
          content: source.content,
          ingested_at: source.ingested_at,
          wiki_pages_touched: source.wiki_pages_touched,
          word_count: length(String.split(source.content || "")),
          metadata: source.metadata,
          checksum: source.checksum,
          inserted_at: source.inserted_at,
          updated_at: source.updated_at
        })
    end
  end

  # Delete a single source by ID
  def delete_source(conn, %{"id" => id}) do
    case Repo.get(RawSource, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Source not found"})
      source ->
        case Repo.delete(source) do
          {:ok, _} ->
            json(conn, %{message: "Source deleted", id: source.id, title: source.title})
          {:error, reason} ->
            conn |> put_status(500) |> json(%{error: inspect(reason)})
        end
    end
  end

  # Reset a workspace: delete all sources, pages, log entries, and index entries
  def reset_workspace(conn, %{"workspace_id" => ws}) do
    import Ecto.Query

    # Don't allow resetting the system workspace
    if ws == "00000000-0000-0000-0000-000000000001" do
      conn |> put_status(403) |> json(%{error: "Cannot reset system workspace"})
    else
      pages_deleted = Repo.delete_all(from p in KnowledgeIndex.Schema.WikiPage, where: p.workspace_id == ^ws)
      sources_deleted = Repo.delete_all(from s in RawSource, where: s.workspace_id == ^ws)
      logs_deleted = Repo.delete_all(from l in KnowledgeIndex.Schema.LogEntry, where: l.workspace_id == ^ws)
      index_deleted = Repo.delete_all(from i in KnowledgeIndex.Schema.IndexEntry, where: i.workspace_id == ^ws)

      json(conn, %{
        message: "Workspace reset",
        workspace_id: ws,
        deleted: %{
          pages: elem(pages_deleted, 0),
          sources: elem(sources_deleted, 0),
          logs: elem(logs_deleted, 0),
          index_entries: elem(index_deleted, 0)
        }
      })
    end
  end

  # Cancel all pending/available Oban ingest jobs for a workspace
  def cancel_jobs(conn, %{"workspace_id" => ws}) do
    import Ecto.Query

    cancelled =
      from(j in Oban.Job,
        where: j.queue == "ingest",
        where: j.state in ["available", "scheduled", "retryable"],
        where: fragment("?->>'workspace_id' = ?", j.args, ^ws)
      )
      |> Repo.update_all(set: [state: "cancelled", cancelled_at: DateTime.utc_now()])

    json(conn, %{message: "Cancelled jobs", workspace_id: ws, count: elem(cancelled, 0)})
  end

  # Re-queue all un-compiled sources for a workspace
  def requeue(conn, %{"workspace_id" => ws}) do
    import Ecto.Query

    sources =
      from(s in RawSource,
        where: s.workspace_id == ^ws and s.wiki_pages_touched == ^[],
        select: s.id
      )
      |> Repo.all()

    for source_id <- sources do
      Oban.insert(Pipeline.Ingest.new(%{"source_id" => source_id, "workspace_id" => ws}))
    end

    json(conn, %{message: "Re-queued #{length(sources)} sources for ingestion", count: length(sources)})
  end
end
