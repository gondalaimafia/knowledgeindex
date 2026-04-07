defmodule KnowledgeIndex.MCP.Handler do
  alias KnowledgeIndex.{Repo, Wiki, Pipeline, Log}
  alias KnowledgeIndex.Schema.{WikiPage, IndexEntry, LogEntry, RawSource}

  import Ecto.Query

  @moduledoc """
  Handles MCP tool calls and resource reads.
  Each tool maps to a Knowledge Index operation.
  """

  def call_tool("ki_query", %{"workspace_id" => ws, "query" => query} = args) do
    file_answer = Map.get(args, "file_answer", true)

    case Pipeline.Query.run(ws, query, file_answer: file_answer) do
      {:ok, answer} -> %{content: [%{type: "text", text: answer}]}
      {:error, reason} -> error_content("Query failed: #{inspect(reason)}")
    end
  end

  def call_tool("ki_ingest", %{"workspace_id" => ws, "source_type" => type, "title" => title, "content" => content} = args) do
    attrs = %{
      workspace_id: ws,
      source_type: type,
      title: title,
      content: content,
      metadata: Map.get(args, "metadata", %{})
    }

    case Repo.insert(RawSource.changeset(%RawSource{}, attrs)) do
      {:ok, source} ->
        Oban.insert(Pipeline.Ingest.new(%{"source_id" => source.id, "workspace_id" => ws}))
        %{content: [%{type: "text", text: "Source '#{title}' queued for ingestion. Wiki will update shortly."}]}
      {:error, changeset} ->
        error_content("Ingest failed: #{inspect(changeset.errors)}")
    end
  end

  def call_tool("ki_search", %{"workspace_id" => ws, "query" => query} = args) do
    limit = Map.get(args, "limit", 10)
    page_type = Map.get(args, "page_type")

    {:ok, results} = Pipeline.Query.search(ws, query, page_type: page_type, limit: limit)

    formatted =
      results
      |> Enum.map(fn page ->
        "[[#{page.slug}]] **#{page.title}** (#{page.page_type})\n#{page.summary}"
      end)
      |> Enum.join("\n\n")

    %{content: [%{type: "text", text: formatted}]}
  end

  def call_tool("ki_get_page", %{"workspace_id" => ws, "slug" => slug}) do
    case Repo.get_by(WikiPage, workspace_id: ws, slug: slug) do
      nil ->
        error_content("Page '#{slug}' not found")
      page ->
        text = """
        # #{page.title}
        Type: #{page.page_type} | Version: #{page.version} | Sources: #{page.source_count}
        Links to: #{Enum.join(page.outbound_links, ", ")}

        #{page.content}
        """
        %{content: [%{type: "text", text: text}]}
    end
  end

  def call_tool("ki_get_index", %{"workspace_id" => ws} = args) do
    category = Map.get(args, "category")

    query = from e in IndexEntry, where: e.workspace_id == ^ws, order_by: e.category

    query = if category, do: where(query, [e], e.category == ^category), else: query

    entries = Repo.all(query)

    formatted =
      entries
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {cat, items} ->
        header = "### #{String.capitalize(cat)}"
        rows = Enum.map(items, &"- [[#{&1.wiki_page_slug}]] #{&1.title} — #{&1.summary}")
        "#{header}\n#{Enum.join(rows, "\n")}"
      end)
      |> Enum.join("\n\n")

    %{content: [%{type: "text", text: formatted}]}
  end

  def call_tool("ki_get_log", %{"workspace_id" => ws} = args) do
    limit = Map.get(args, "limit", 20)
    operation = Map.get(args, "operation")

    query =
      from l in LogEntry,
        where: l.workspace_id == ^ws,
        order_by: [desc: l.inserted_at],
        limit: ^limit

    query = if operation, do: where(query, [l], l.operation == ^operation), else: query

    entries = Repo.all(query)

    formatted =
      entries
      |> Enum.map(fn entry ->
        date = Calendar.strftime(entry.inserted_at, "%Y-%m-%d")
        "## [#{date}] #{entry.operation} | #{entry.label}"
      end)
      |> Enum.join("\n")

    %{content: [%{type: "text", text: formatted}]}
  end

  def call_tool("ki_lint", %{"workspace_id" => ws}) do
    Oban.insert(Pipeline.Lint.new(%{"workspace_id" => ws}))
    %{content: [%{type: "text", text: "Lint pass queued. Check the log in a few minutes for results."}]}
  end

  def call_tool(name, _args) do
    error_content("Unknown tool: #{name}")
  end

  def read_resource("knowledge-index://index") do
    # Return full index as JSON
    %{contents: [%{type: "text", text: "Use ki_get_index tool with your workspace_id to access the index."}]}
  end

  def read_resource("knowledge-index://log") do
    %{contents: [%{type: "text", text: "Use ki_get_log tool with your workspace_id to access the log."}]}
  end

  def read_resource(uri) do
    %{contents: [%{type: "text", text: "Unknown resource: #{uri}"}]}
  end

  defp error_content(message) do
    %{isError: true, content: [%{type: "text", text: message}]}
  end
end
