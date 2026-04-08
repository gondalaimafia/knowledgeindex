defmodule KnowledgeIndex.Log do
  alias KnowledgeIndex.Repo
  alias KnowledgeIndex.Schema.LogEntry

  def append(workspace_id, operation, label, detail \\ %{}, initiated_by \\ "system") do
    %LogEntry{}
    |> LogEntry.changeset(%{
      workspace_id: workspace_id,
      operation: to_string(operation),
      label: label,
      detail: detail,
      initiated_by: initiated_by
    })
    |> Repo.insert()
  end
end
