defmodule Xwa.Documents.DocumentContent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  @foreign_key_type :binary_id

  schema "document_contents" do
    belongs_to :document, Xwa.Documents.Document,
      foreign_key: :document_id,
      primary_key: true,
      type: :binary_id

    # Raw bytes of the original document (PDF, DOCX, etc.)
    # May be AES-256-GCM ciphertext if the parent document has an encryption_tier set.
    field :content, :binary

    # Plain-text extraction — used for display and re-ingestion.
    # Stored as binary so it can hold either UTF-8 text or AES-256-GCM ciphertext.
    # Check the parent document's encryption_tier to know which it is.
    field :extracted_text, :binary

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for storing inline document content.
  Only used when storage_backend is :postgres.
  At least one of content or extracted_text must be present.
  """
  def changeset(document_content, attrs) do
    document_content
    |> cast(attrs, [:document_id, :content, :extracted_text])
    |> validate_required([:document_id])
    |> validate_at_least_one_content_field()
    |> assoc_constraint(:document)
  end

  defp validate_at_least_one_content_field(changeset) do
    content = get_field(changeset, :content)
    extracted_text = get_field(changeset, :extracted_text)

    if is_nil(content) and is_nil(extracted_text) do
      add_error(changeset, :content, "at least one of content or extracted_text must be present")
    else
      changeset
    end
  end
end
