defmodule KnowledgeIndex.Repo do
  use Ecto.Repo,
    otp_app: :knowledge_index,
    adapter: Ecto.Adapters.Postgres
end
