defmodule Xwa.Documents.Document do
  use Ecto.Schema
  import Ecto.Changeset

  @storage_backends ~w(postgres local s3 url)
  @source_types ~w(aspirational operational external)
  @corpus_layers ~w(self_description internal_record external_context)
  @ingestion_statuses ~w(pending processing complete failed)
  @encryption_tiers ~w(app user)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "documents" do
    field :title, :string
    field :filename, :string

    # Storage
    field :storage_backend, :string, default: "local"
    field :storage_ref, :string

    # Content integrity
    field :content_hash, :string
    field :content_type, :string
    field :byte_size, :integer

    # Document provenance
    field :document_date, :date

    # Classification — mirrors corpus_layer / source_type on graph Node
    field :source_type, :string
    field :corpus_layer, :string

    # Flexible domain-specific metadata
    # e.g. %{"preacher" => "...", "series" => "...", "scripture" => "..."}
    field :metadata, :map, default: %{}

    # Ingestion lifecycle
    field :ingested_at, :utc_datetime
    field :ingestion_status, :string, default: "pending"
    field :ingestion_error, :string

    # Encryption
    # nil   — content is stored plaintext
    # "app" — content encrypted with the app-level ENCRYPTION_KEY
    # "user" — content encrypted with the owner's per-user key (stored in user_keys)
    field :encryption_tier, :string

    # Audit
    field :created_by, :binary_id

    has_one :content, Xwa.Documents.DocumentContent, foreign_key: :document_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for registering a new document.

  Does not handle content — content is managed separately via
  `Xwa.Documents.DocumentContent` to keep document rows lean.
  """
  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :title,
      :filename,
      :storage_backend,
      :storage_ref,
      :content_hash,
      :content_type,
      :byte_size,
      :document_date,
      :source_type,
      :corpus_layer,
      :metadata,
      :ingested_at,
      :ingestion_status,
      :ingestion_error,
      :encryption_tier,
      :created_by
    ])
    |> validate_required([:title, :storage_backend])
    |> validate_inclusion(:storage_backend, @storage_backends)
    |> validate_inclusion(:source_type, @source_types)
    |> validate_inclusion(:corpus_layer, @corpus_layers)
    |> validate_inclusion(:ingestion_status, @ingestion_statuses)
    |> validate_inclusion(:encryption_tier, @encryption_tiers, skip_is_nil: true)
    |> validate_storage_ref()
    |> unique_constraint(:content_hash,
      name: :documents_content_hash_unique,
      message: "a document with this content already exists"
    )
  end

  @doc """
  Changeset for updating ingestion lifecycle fields only.
  Used by the ingestion pipeline to advance status without touching metadata.
  """
  def ingestion_changeset(document, attrs) do
    document
    |> cast(attrs, [:ingestion_status, :ingestion_error, :ingested_at])
    |> validate_required([:ingestion_status])
    |> validate_inclusion(:ingestion_status, @ingestion_statuses)
  end

  # storage_ref is required for every backend except :postgres,
  # which stores content in the document_contents table.
  defp validate_storage_ref(changeset) do
    backend = get_field(changeset, :storage_backend)
    ref = get_field(changeset, :storage_ref)

    if backend != "postgres" and is_nil(ref) do
      add_error(changeset, :storage_ref, "is required for storage backend #{inspect(backend)}")
    else
      changeset
    end
  end
end
