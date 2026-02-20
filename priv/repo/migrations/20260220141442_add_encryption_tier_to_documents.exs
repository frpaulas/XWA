defmodule Xwa.Repo.Migrations.AddEncryptionTierToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      # nil     — document content is stored plaintext
      # "app"   — content encrypted with the app-level ENCRYPTION_KEY
      # "user"  — content encrypted with the document owner's per-user key
      #           (which is itself encrypted with the app key in user_keys)
      add :encryption_tier, :string, null: true, default: nil
    end

    create constraint(:documents, :valid_encryption_tier,
             check: "encryption_tier IS NULL OR encryption_tier IN ('app', 'user')"
           )
  end
end
