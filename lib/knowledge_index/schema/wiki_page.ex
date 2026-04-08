defmodule KnowledgeIndex.Schema.WikiPage do
  use Ecto.Schema
  import Ecto.Changeset

  @moduledoc """
  A compiled wiki page — the LLM-maintained layer between raw PM artifacts
  and the AI that queries them.

  Per Karpathy's LLM Wiki pattern: the wiki is a persistent, compounding artifact.
  Raw sources are compiled once into structured pages and kept current.
  Not re-derived on every query.

  Per Alex's architecture: pages are sovereign, structured, queryable via MCP.
  """

  @page_types ~w(entity concept decision synthesis source_summary outcome contradiction index log)

  schema "wiki_pages" do
    field :workspace_id, :binary_id
    field :title, :string
    field :slug, :string             # url-safe identifier, stable across updates
    field :page_type, :string        # entity | concept | decision | synthesis | source_summary | outcome | contradiction | index | log
    field :content, :string          # full markdown body — LLM owns and maintains this
    field :summary, :string          # one-line summary for index.md
    field :embedding, Pgvector.Ecto.Vector  # 1536-dim, text-embedding-3-small
    field :source_count, :integer, default: 0   # how many raw artifacts contributed to this page
    field :inbound_links, {:array, :string}, default: []  # slugs of pages that link here
    field :outbound_links, {:array, :string}, default: []  # slugs this page links to
    field :contradictions, {:array, :string}, default: []  # slugs of pages with conflicting claims
    field :stale, :boolean, default: false  # flagged by lint — newer sources may have superseded claims
    field :version, :integer, default: 1    # increments on every LLM update
    field :metadata, :map, default: %{}     # domain-specific frontmatter

    timestamps()
  end

  def changeset(page, attrs) do
    page
    |> cast(attrs, [:workspace_id, :title, :slug, :page_type, :content, :summary,
                    :embedding, :source_count, :inbound_links, :outbound_links,
                    :contradictions, :stale, :version, :metadata])
    |> validate_required([:workspace_id, :title, :slug, :page_type, :content])
    |> validate_inclusion(:page_type, @page_types)
    |> unique_constraint([:workspace_id, :slug])
    |> validate_length(:summary, max: 200)
  end
end
