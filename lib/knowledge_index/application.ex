defmodule KnowledgeIndex.Application do
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Run migrations on boot (before starting supervision tree)
    migrate()

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
    Supervisor.start_link(children, opts)
  end

  defp oban_config do
    [
      repo: KnowledgeIndex.Repo,
      queues: [
        ingest: 5,      # artifact ingestion → wiki compilation
        lint: 2,        # periodic wiki health checks
        watch: 10,      # real-time artifact change detection
        query: 5        # async query answer filing
      ]
    ]
  end

  defp migrate do
    Logger.info("[KnowledgeIndex] Running migrations...")
    {:ok, _, _} = Ecto.Migrator.with_repo(KnowledgeIndex.Repo, &Ecto.Migrator.run(&1, :up, all: true))
    Logger.info("[KnowledgeIndex] Migrations complete")
  rescue
    e ->
      Logger.warning("[KnowledgeIndex] Migration failed: #{inspect(e)} — continuing anyway")
  end
end
