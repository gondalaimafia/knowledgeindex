import Config

config :knowledge_index, KnowledgeIndex.Repo,
  url: System.get_env("DATABASE_URL") || "postgres://localhost/knowledge_index_dev",
  pool_size: 10

config :knowledge_index, KnowledgeIndexWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  secret_key_base: "dev-secret-key-base-that-is-at-least-64-characters-long-for-phoenix",
  server: true

config :knowledge_index,
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY") || "dev",
  voyage_api_key: System.get_env("VOYAGE_API_KEY") || "dev"
