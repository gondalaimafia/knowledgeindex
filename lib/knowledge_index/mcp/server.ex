defmodule KnowledgeIndex.MCP.Server do
  use GenServer

  alias KnowledgeIndex.MCP.{Handler, Protocol}

  require Logger

  @moduledoc """
  MCP server exposing the Knowledge Index to any compatible AI client.

  Per Alex's architecture: sovereign knowledge infrastructure exposed
  via standard protocol. Claude, Cursor, any agent — one interface.

  Tools exposed:
    - ki_query          Query the wiki in natural language
    - ki_ingest         Add a raw source and compile it into wiki pages
    - ki_search         Search wiki pages by keyword or semantic similarity
    - ki_get_page       Fetch a specific wiki page by slug
    - ki_get_index      Get the full wiki index
    - ki_get_log        Get recent operations log
    - ki_lint           Trigger a wiki health check

  Resources exposed:
    - knowledge-index://index      The full index
    - knowledge-index://page/{slug}  Any wiki page
    - knowledge-index://log        Recent operation log
  """

  # ──────────────────────────────────────────────────────────────────────────
  # Supervision
  # ──────────────────────────────────────────────────────────────────────────

  def start_link(opts) do
    port = Keyword.get(opts, :port, 4001)
    GenServer.start_link(__MODULE__, port, name: __MODULE__)
  end

  @impl GenServer
  def init(port) do
    {:ok, listen_socket} = :gen_tcp.listen(port, [
      :binary,
      packet: :line,
      active: false,
      reuseaddr: true
    ])

    Logger.info("[MCP] Knowledge Index server listening on port #{port}")

    # Accept connections in separate process
    spawn_link(fn -> accept_loop(listen_socket) end)

    {:ok, %{port: port, listen_socket: listen_socket}}
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Connection handling
  # ──────────────────────────────────────────────────────────────────────────

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        spawn(fn -> handle_connection(socket) end)
        accept_loop(listen_socket)
      {:error, :closed} ->
        :ok
      {:error, reason} ->
        Logger.error("[MCP] Accept error: #{inspect(reason)}")
        accept_loop(listen_socket)
    end
  end

  defp handle_connection(socket) do
    case recv_message(socket) do
      {:ok, message} ->
        response = dispatch(message)
        send_response(socket, response)
        handle_connection(socket)
      {:error, :closed} ->
        :ok
    end
  end

  defp recv_message(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        case Jason.decode(String.trim(data)) do
          {:ok, message} -> {:ok, message}
          {:error, _} -> {:error, :invalid_json}
        end
      {:error, :closed} -> {:error, :closed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_response(socket, response) do
    :gen_tcp.send(socket, Jason.encode!(response) <> "\n")
  end

  # ──────────────────────────────────────────────────────────────────────────
  # MCP message dispatch
  # ──────────────────────────────────────────────────────────────────────────

  defp dispatch(%{"method" => "initialize"} = msg) do
    Protocol.initialize_response(msg["id"])
  end

  defp dispatch(%{"method" => "tools/list"} = msg) do
    Protocol.tools_list_response(msg["id"], tool_definitions())
  end

  defp dispatch(%{"method" => "tools/call", "params" => params} = msg) do
    result = Handler.call_tool(params["name"], params["arguments"] || %{})
    Protocol.tool_result_response(msg["id"], result)
  end

  defp dispatch(%{"method" => "resources/list"} = msg) do
    Protocol.resources_list_response(msg["id"], resource_definitions())
  end

  defp dispatch(%{"method" => "resources/read", "params" => params} = msg) do
    result = Handler.read_resource(params["uri"])
    Protocol.resource_result_response(msg["id"], result)
  end

  defp dispatch(msg) do
    Protocol.error_response(Map.get(msg, "id"), :method_not_found, "Unknown method")
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Tool and resource definitions
  # ──────────────────────────────────────────────────────────────────────────

  defp tool_definitions do
    [
      %{
        name: "ki_query",
        description: "Query the PM Knowledge Index in natural language. Returns a synthesized answer with citations from wiki pages. Good answers are automatically filed back into the wiki.",
        inputSchema: %{
          type: "object",
          properties: %{
            workspace_id: %{type: "string", description: "Workspace identifier"},
            query: %{type: "string", description: "Natural language question about the product"},
            file_answer: %{type: "boolean", description: "File the answer back to the wiki (default: true)"}
          },
          required: ["workspace_id", "query"]
        }
      },
      %{
        name: "ki_ingest",
        description: "Add a raw PM artifact and compile it into wiki pages. A single source typically touches 10-15 wiki pages.",
        inputSchema: %{
          type: "object",
          properties: %{
            workspace_id: %{type: "string"},
            source_type: %{type: "string", enum: ["prd", "transcript", "feedback", "decision", "analytics", "competitive", "retro", "slack_thread", "email"]},
            title: %{type: "string"},
            content: %{type: "string", description: "Full text of the artifact"},
            metadata: %{type: "object", description: "Origin, author, date, url, etc."}
          },
          required: ["workspace_id", "source_type", "title", "content"]
        }
      },
      %{
        name: "ki_search",
        description: "Search wiki pages by keyword or semantic similarity. Returns matching pages with summaries.",
        inputSchema: %{
          type: "object",
          properties: %{
            workspace_id: %{type: "string"},
            query: %{type: "string"},
            page_type: %{type: "string", description: "Filter by page type: entity, concept, decision, outcome, etc."},
            limit: %{type: "integer", default: 10}
          },
          required: ["workspace_id", "query"]
        }
      },
      %{
        name: "ki_get_page",
        description: "Fetch a specific wiki page by slug.",
        inputSchema: %{
          type: "object",
          properties: %{
            workspace_id: %{type: "string"},
            slug: %{type: "string", description: "Wiki page slug, e.g. feature-smart-notifications"}
          },
          required: ["workspace_id", "slug"]
        }
      },
      %{
        name: "ki_get_index",
        description: "Get the full wiki index — a catalog of every page with one-line summaries, organized by category.",
        inputSchema: %{
          type: "object",
          properties: %{
            workspace_id: %{type: "string"},
            category: %{type: "string", description: "Filter by category: entities, concepts, decisions, outcomes, sources"}
          },
          required: ["workspace_id"]
        }
      },
      %{
        name: "ki_get_log",
        description: "Get the operation log — recent ingests, queries, lint passes, and outcome filings.",
        inputSchema: %{
          type: "object",
          properties: %{
            workspace_id: %{type: "string"},
            limit: %{type: "integer", default: 20},
            operation: %{type: "string", description: "Filter by operation type"}
          },
          required: ["workspace_id"]
        }
      },
      %{
        name: "ki_lint",
        description: "Trigger a wiki health check. Finds contradictions, orphan pages, stale claims, and missing outcome pages.",
        inputSchema: %{
          type: "object",
          properties: %{
            workspace_id: %{type: "string"}
          },
          required: ["workspace_id"]
        }
      }
    ]
  end

  defp resource_definitions do
    [
      %{
        uri: "knowledge-index://index",
        name: "Wiki Index",
        description: "Full catalog of all wiki pages with one-line summaries",
        mimeType: "application/json"
      },
      %{
        uri: "knowledge-index://log",
        name: "Operation Log",
        description: "Append-only log of all Knowledge Index operations",
        mimeType: "application/json"
      }
    ]
  end
end
