defmodule Xwa.Repo.Migrations.CreateDocuments do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      # Human-readable identity
      add :title, :string, null: false
      add :filename, :string

      # Where the content lives
      add :storage_backend, :string, null: false, default: "local"
      add :storage_ref, :string
      # ^ interpreted per backend:
      #   :postgres -> null (content in document_contents)
      #   :local    -> absolute or relative filesystem path
      #   :s3       -> "bucket/key"
      #   :url      -> full URL

      # Content integrity
      add :content_hash, :string
      # ^ sha256 hex digest of the raw document bytes
      add :content_type, :string
      # ^ MIME type e.g. "application/pdf", "text/plain"
      add :byte_size, :integer

      # Document provenance (distinct from XWA ingestion time)
      add :document_date, :date
      # ^ when the institution produced this document

      # Classification — mirrors corpus_layer / source_type on Node
      # stored here so queries can be driven from the document side too
      add :source_type, :string
      # ^ "aspirational" | "operational" | "external"
      add :corpus_layer, :string
      # ^ "self_description" | "internal_record" | "external_context"

      # Flexible bag for domain-specific metadata
      # e.g. preacher name, series title, congregation, scripture refs
      add :metadata, :map, default: %{}

      # Ingestion lifecycle
      add :ingested_at, :utc_datetime
      add :ingestion_status, :string, null: false, default: "pending"
      # ^ "pending" | "processing" | "complete" | "failed"
      add :ingestion_error, :text

      # Audit
      add :created_by, :uuid

      timestamps(type: :utc_datetime)
    end

    # Inline content storage for :postgres backend.
    # Kept in a separate table to avoid ballooning the documents rows.
    create table(:document_contents, primary_key: false) do
      add :document_id, references(:documents, type: :uuid, on_delete: :delete_all),
        primary_key: true

      add :content, :binary
      # ^ raw bytes — text documents, PDFs, etc.
      add :extracted_text, :text
      # ^ plain-text extraction for display and re-ingestion without re-parsing

      timestamps(type: :utc_datetime)
    end

    # Check constraints — must follow table creation
    create constraint(:documents, :valid_storage_backend,
             check: "storage_backend IN ('postgres', 'local', 's3', 'url')"
           )

    create constraint(:documents, :valid_source_type,
             check:
               "source_type IN ('aspirational', 'operational', 'external') OR source_type IS NULL"
           )

    create constraint(:documents, :valid_corpus_layer,
             check:
               "corpus_layer IN ('self_description', 'internal_record', 'external_context') OR corpus_layer IS NULL"
           )

    create constraint(:documents, :valid_ingestion_status,
             check: "ingestion_status IN ('pending', 'processing', 'complete', 'failed')"
           )

    # storage_ref required for all backends except :postgres
    create constraint(:documents, :storage_ref_required,
             check: "storage_backend = 'postgres' OR storage_ref IS NOT NULL"
           )

    create index(:documents, [:storage_backend])
    create index(:documents, [:ingestion_status])
    create index(:documents, [:source_type])
    create index(:documents, [:corpus_layer])
    create index(:documents, [:document_date])
    create index(:documents, [:created_by])

    create unique_index(:documents, [:content_hash],
             where: "content_hash IS NOT NULL",
             name: :documents_content_hash_unique
           )
  end
end
