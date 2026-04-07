defmodule KnowledgeIndex.Wiki do
  alias KnowledgeIndex.Repo
  alias KnowledgeIndex.Schema.{WikiPage, IndexEntry}

  import Ecto.Query

  def load_index(workspace_id) do
    entries = Repo.all(
      from e in IndexEntry,
        where: e.workspace_id == ^workspace_id,
        order_by: [e.category, e.title]
    )
    {:ok, entries}
  end

  def all_pages(workspace_id) do
    pages = Repo.all(
      from p in WikiPage,
        where: p.workspace_id == ^workspace_id,
        order_by: p.title
    )
    {:ok, pages}
  end
end
