import Config

config :knowledge_index, KnowledgeIndexWeb.Endpoint,
  server: true

# All runtime config (DATABASE_URL, SECRET_KEY_BASE, API keys)
# is in runtime.exs — not here. This file runs at BUILD time
# when secrets are not available.
