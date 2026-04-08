import Config

if config_env() == :prod do
  # Parse DATABASE_URL into individual fields
  # Neon format: postgresql://user:pass@host/dbname?params
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL not set"

  # Use Ecto's built-in URL parser which handles all edge cases
  keyword = Ecto.Repo.Supervisor.parse_url(database_url)

  config :knowledge_index, KnowledgeIndex.Repo,
    [
      ssl: [verify: :verify_none],
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
      connect_timeout: 30_000,
      queue_target: 10_000,
      queue_interval: 30_000
    ] ++ keyword

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE not set"

  host = System.get_env("PHX_HOST") || "knowledge-index.fly.dev"
  port = String.to_integer(System.get_env("PORT") || "8080")

  config :knowledge_index, KnowledgeIndexWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base

  config :knowledge_index,
    anthropic_api_key: System.fetch_env!("ANTHROPIC_API_KEY"),
    voyage_api_key: System.fetch_env!("VOYAGE_API_KEY")
end
