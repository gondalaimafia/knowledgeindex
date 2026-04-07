import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL not set"

  # Parse Neon URL into explicit fields (per Neon's official Elixir guide)
  uri = URI.parse(database_url)

  {username, password} =
    case String.split(uri.userinfo || "", ":") do
      [u, p] -> {u, p}
      [u] -> {u, ""}
      _ -> raise "Invalid DATABASE_URL userinfo"
    end

  database =
    case uri.path do
      "/" <> db -> db
      _ -> "neondb"
    end

  config :knowledge_index, KnowledgeIndex.Repo,
    hostname: uri.host,
    port: uri.port || 5432,
    username: username,
    password: password,
    database: database,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    ssl: [verify: :verify_none],
    connect_timeout: 30_000,
    queue_target: 10_000,
    queue_interval: 30_000

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
