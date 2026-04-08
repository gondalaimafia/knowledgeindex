import Config

config :knowledge_index,
  ecto_repos: [KnowledgeIndex.Repo]

config :knowledge_index, KnowledgeIndexWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [json: KnowledgeIndexWeb.ErrorJSON]],
  pubsub_server: KnowledgeIndex.PubSub

config :knowledge_index, Oban,
  repo: KnowledgeIndex.Repo,
  queues: [ingest: 5, lint: 2, watch: 10, query: 5]

import_config "#{config_env()}.exs"
