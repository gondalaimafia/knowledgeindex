defmodule KnowledgeIndex.Schema.RawSource do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  An immutable raw PM artifact — the source of truth.

  The LLM reads from raw sources but never modifies them.
  All synthesis, cross-referencing, and maintenance happens in WikiPage.

  Source types map to the PM workflow:
  - prd: product requirements document
  - transcript: user interview, meeting, customer call
  - feedback: support ticket, NPS response, feature request
  - decision: architectural or product decision log entry
  - analytics: metric snapshot, dashboard export, experiment result
  - competitive: competitor research, market analysis
  - retro: sprint or feature retrospective
  """

  @source_types ~w(
    artifact prd one_pager roadmap strategy_doc vision_doc okr decision
    user_research user_interview usability_test survey_results persona
    competitive market_research feedback customer_call support_ticket
    nps_verbatim case_study spec adr design_doc runbook changelog
    post_mortem transcript meeting_notes retro email slack_thread
    pitch_deck sales_playbook pricing_doc go_to_market internal_doc
    user_guide faq onboarding_doc policy analytics metric_doc
    dashboard_export other
  )

  schema "raw_sources" do
    field :workspace_id, :binary_id
    field :source_type, :string
    field :title, :string
    field :content, :string         # raw text content
    field :metadata, :map, default: %{}  # origin, author, date, url, etc.
    field :ingested_at, :utc_datetime    # when the LLM compiled this into wiki pages
    field :wiki_pages_touched, {:array, :string}, default: []  # slugs updated during ingest
    field :checksum, :string        # SHA-256 of content — detect changes without re-reading

    timestamps()
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:workspace_id, :source_type, :title, :content, :metadata,
                    :ingested_at, :wiki_pages_touched, :checksum])
    |> validate_required([:workspace_id, :source_type, :title, :content])
    |> validate_inclusion(:source_type, @source_types)
    |> put_checksum()
  end

  defp put_checksum(changeset) do
    case get_change(changeset, :content) do
      nil -> changeset
      content -> put_change(changeset, :checksum, :crypto.hash(:sha256, content) |> Base.encode16(case: :lower))
    end
  end
end
