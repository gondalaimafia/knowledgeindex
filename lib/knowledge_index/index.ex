defmodule KnowledgeIndex.Index do
  alias KnowledgeIndex.Repo
  alias KnowledgeIndex.Schema.{WikiPage, IndexEntry}

  import Ecto.Query

  def rebuild(workspace_id) do
    pages = Repo.all(
      from p in WikiPage,
        where: p.workspace_id == ^workspace_id
    )

    naive_now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    utc_now = DateTime.utc_now() |> DateTime.truncate(:second)

    entries =
      Enum.map(pages, fn page ->
        last_updated = case page.updated_at do
          %DateTime{} = dt -> dt
          %NaiveDateTime{} = ndt -> DateTime.from_naive!(ndt, "Etc/UTC")
          _ -> utc_now
        end

        %{
          workspace_id: workspace_id,
          wiki_page_slug: page.slug,
          title: page.title,
          summary: page.summary || "",
          page_type: page.page_type,
          category: categorize(page.page_type),
          source_count: page.source_count,
          last_updated: last_updated,
          inserted_at: naive_now,
          updated_at: naive_now
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
