defmodule KnowledgeIndex.Schema.IndexEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  The compiled index — a catalog of every wiki page with one-line summaries.

  Per Karpathy: index.md is content-oriented. The LLM reads the index first
  to find relevant pages, then drills into them. Works at moderate scale
  (~100 sources, ~hundreds of pages) without needing embedding-based RAG.

  We store this as structured DB rows rather than a flat file so we can
  query it efficiently and serve it via MCP.
  """

  schema "index_entries" do
    field :workspace_id, :binary_id
    field :wiki_page_slug, :string
    field :title, :string
    field :summary, :string
    field :page_type, :string
    field :category, :string        # entities | concepts | decisions | outcomes | sources
    field :source_count, :integer, default: 0
    field :last_updated, :utc_datetime

    timestamps()
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:workspace_id, :wiki_page_slug, :title, :summary, :page_type,
                    :category, :source_count, :last_updated])
    |> validate_required([:workspace_id, :wiki_page_slug, :title, :summary])
    |> unique_constraint([:workspace_id, :wiki_page_slug])
  end
end
