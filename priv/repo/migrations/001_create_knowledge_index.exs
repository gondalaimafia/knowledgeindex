defmodule KnowledgeIndex.Repo.Migrations.CreateKnowledgeIndex do
  use Ecto.Migration

  def up do
    # Enable pgvector
    execute "CREATE EXTENSION IF NOT EXISTS vector"

    # Raw sources — immutable PM artifacts
    create table(:raw_sources) do
      add :workspace_id, :uuid, null: false
      add :source_type, :string, null: false
      add :title, :string, null: false
      add :content, :text, null: false
      add :metadata, :jsonb, default: "{}"
      add :ingested_at, :utc_datetime
      add :wiki_pages_touched, {:array, :string}, default: []
      add :checksum, :string

      timestamps()
    end

    create index(:raw_sources, [:workspace_id])
    create index(:raw_sources, [:workspace_id, :source_type])
    create index(:raw_sources, [:checksum])

    # Wiki pages — the persistent, compounding artifact
    create table(:wiki_pages) do
      add :workspace_id, :uuid, null: false
      add :title, :string, null: false
      add :slug, :string, null: false
      add :page_type, :string, null: false
      add :content, :text, null: false
      add :summary, :string
      add :embedding, :vector, size: 1024
      add :source_count, :integer, default: 0
      add :inbound_links, {:array, :string}, default: []
      add :outbound_links, {:array, :string}, default: []
      add :contradictions, {:array, :string}, default: []
      add :stale, :boolean, default: false
      add :version, :integer, default: 1
      add :metadata, :jsonb, default: "{}"

      timestamps()
    end

    create unique_index(:wiki_pages, [:workspace_id, :slug])
    create index(:wiki_pages, [:workspace_id])
    create index(:wiki_pages, [:workspace_id, :page_type])
    create index(:wiki_pages, [:stale])

    # pgvector HNSW index for fast similarity search
    execute """
      CREATE INDEX wiki_pages_embedding_idx ON wiki_pages
      USING hnsw (embedding vector_cosine_ops)
      WITH (m = 16, ef_construction = 64)
    
    """

    # Index entries — catalog for fast navigation
    create table(:index_entries) do
      add :workspace_id, :uuid, null: false
      add :wiki_page_slug, :string, null: false
      add :title, :string, null: false
      add :summary, :string, null: false
      add :page_type, :string
      add :category, :string
      add :source_count, :integer, default: 0
      add :last_updated, :utc_datetime

      timestamps()
    end

    create unique_index(:index_entries, [:workspace_id, :wiki_page_slug])
    create index(:index_entries, [:workspace_id, :category])

    # Log entries — append-only operation history
    create table(:log_entries) do
      add :workspace_id, :uuid, null: false
      add :operation, :string, null: false
      add :label, :string, null: false
      add :detail, :jsonb, default: "{}"
      add :initiated_by, :string

      timestamps(updated_at: false)
    end

    create index(:log_entries, [:workspace_id])
    create index(:log_entries, [:workspace_id, :operation])
    create index(:log_entries, [:inserted_at])

    # .pmrules versions — for the autoresearch optimizer (Phase 3)
    create table(:pmrules_versions) do
      add :workspace_id, :uuid, null: false
      add :version_number, :integer, null: false
      add :content, :text, null: false
      add :accuracy_score, :float
      add :features_built, :integer, default: 0
      add :metrics_hit, :integer, default: 0
      add :status, :string, default: "active"
      add :committed_at, :utc_datetime

      timestamps()
    end

    create unique_index(:pmrules_versions, [:workspace_id, :version_number])
    create index(:pmrules_versions, [:workspace_id, :status])
  end

  def down do
    drop table(:pmrules_versions)
    drop table(:log_entries)
    drop table(:index_entries)
    drop table(:wiki_pages)
    drop table(:raw_sources)
  end
end
