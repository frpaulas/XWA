defmodule Xwa.Repo.Migrations.CreateUserKeys do
  use Ecto.Migration

  def change do
    create table(:user_keys, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      # The user this key belongs to
      add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false

      # The user's 32-byte encryption key, itself encrypted with the app-level
      # ENCRYPTION_KEY (AES-256-GCM). Stored as binary: iv <> tag <> ciphertext.
      # Never nil once created — a user_keys row only exists if per-user
      # encryption has been opted into.
      add :encrypted_key, :binary, null: false

      # Tier label for future-proofing (currently always "user")
      add :tier, :string, null: false, default: "user"

      timestamps(type: :utc_datetime)
    end

    # One key record per user per tier
    create unique_index(:user_keys, [:user_id, :tier])

    create index(:user_keys, [:user_id])

    create constraint(:user_keys, :valid_tier, check: "tier IN ('user')")
  end
end
