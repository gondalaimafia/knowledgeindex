defmodule KnowledgeIndex.Schema.LogEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  Append-only log of all Knowledge Index operations.

  Per Karpathy: the log is chronological. An append-only record of what happened
  and when — ingests, queries, lint passes. The log gives a timeline of the wiki's
  evolution and helps the LLM understand what's been done recently.

  Format mirrors Karpathy's convention:
    [2026-04-07] ingest | PRD: Smart Notifications v2
    [2026-04-07] query  | What features shipped this quarter?
    [2026-04-07] lint   | Found 3 contradictions, 2 orphan pages
  """

  @operation_types ~w(ingest query lint watch pmrules_update outcome_filed contradiction_flagged)

  schema "log_entries" do
    field :workspace_id, :binary_id
    field :operation, :string        # ingest | query | lint | watch | pmrules_update | outcome_filed
    field :label, :string            # human-readable: "PRD: Smart Notifications v2"
    field :detail, :map, default: %{}  # pages_touched, contradictions_found, query_text, etc.
    field :initiated_by, :string     # user_id or "agent:drift" | "agent:discovery" | "agent:lint"

    timestamps(updated_at: false)    # log is append-only, no updates
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:workspace_id, :operation, :label, :detail, :initiated_by])
    |> validate_required([:workspace_id, :operation, :label])
    |> validate_inclusion(:operation, @operation_types)
  end
end
