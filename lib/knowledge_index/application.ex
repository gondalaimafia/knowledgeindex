defmodule KnowledgeIndex.Application do
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      # Database
      KnowledgeIndex.Repo,

      # Background jobs (ingest, lint, watch pipelines)
      {Oban, oban_config()},

      # Real-time pubsub (wiki updates → connected editors)
      {Phoenix.PubSub, name: KnowledgeIndex.PubSub},

      # MCP server on port 4001
      {KnowledgeIndex.MCP.Server, port: 4001},

      # Phoenix HTTP API
      KnowledgeIndexWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: KnowledgeIndex.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Run migrations after the Repo is up
    migrate()

    result
  end

  defp oban_config do
    [
      repo: KnowledgeIndex.Repo,
      queues: [
        ingest: 10,     # fast now — no LLM, just storage + embedding
        lint: 2,        # periodic health checks (keep as-is)
        query: 5        # async query filing (keep as-is)
      ]
    ]
  end

  defp migrate do
    Logger.info("[KnowledgeIndex] Running migrations...")
    path = Application.app_dir(:knowledge_index, "priv/repo/migrations")
    Ecto.Migrator.run(KnowledgeIndex.Repo, path, :up, all: true)
    Logger.info("[KnowledgeIndex] Migrations complete")
  rescue
    e ->
      Logger.warning("[KnowledgeIndex] Migration failed: #{inspect(e)} — continuing anyway")
  end
end
