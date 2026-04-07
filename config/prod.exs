import Config

# All real config is in runtime.exs
# This file must NOT set any Repo config — otherwise it overrides runtime.exs
config :knowledge_index, KnowledgeIndexWeb.Endpoint,
  server: true
