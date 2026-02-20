defmodule Xwa.Repo.Migrations.AlterDocumentContentsExtractedTextToBinary do
  use Ecto.Migration

  # Ecto's modify helper generates ALTER COLUMN ... TYPE bytea without a USING
  # clause, which Postgres rejects for text → bytea. Raw SQL is required.

  def up do
    execute "ALTER TABLE document_contents ALTER COLUMN extracted_text TYPE bytea USING extracted_text::bytea"
  end

  def down do
    execute "ALTER TABLE document_contents ALTER COLUMN extracted_text TYPE text USING extracted_text::text"
  end
end
