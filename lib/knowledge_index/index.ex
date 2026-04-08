defmodule KnowledgeIndex.Index do
  alias KnowledgeIndex.Repo
  alias KnowledgeIndex.Schema.{WikiPage, IndexEntry}

  import Ecto.Query

  def rebuild(workspace_id) do
    pages = Repo.all(
      from p in WikiPage,
        where: p.workspace_id == ^workspace_id
    )

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    entries =
      Enum.map(pages, fn page ->
        %{
          workspace_id: workspace_id,
          wiki_page_slug: page.slug,
          title: page.title,
          summary: page.summary || "",
          page_type: page.page_type,
          category: categorize(page.page_type),
          source_count: page.source_count,
          last_updated: page.updated_at,
          inserted_at: now,
          updated_at: now
        }
      end)

    case Repo.transaction(fn ->
      Repo.delete_all(from e in IndexEntry, where: e.workspace_id == ^workspace_id)
      Repo.insert_all(IndexEntry, entries)
    end) do
      {:ok, _} -> {:ok, length(pages)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp categorize("entity"), do: "entities"
  defp categorize("concept"), do: "concepts"
  defp categorize("decision"), do: "decisions"
  defp categorize("outcome"), do: "outcomes"
  defp categorize("source_summary"), do: "sources"
  defp categorize("synthesis"), do: "syntheses"
  defp categorize(_), do: "other"
end
