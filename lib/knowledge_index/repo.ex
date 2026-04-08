defmodule KnowledgeIndex.Repo do
  use Ecto.Repo,
    otp_app: :knowledge_index,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_type, config) do
    {:ok, Keyword.put(config, :types, KnowledgeIndex.PostgrexTypes)}
  end
end
