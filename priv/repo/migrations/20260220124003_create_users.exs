defmodule Xwa.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      # Identity from OAuth provider
      add :email, :string, null: false
      add :name, :string
      add :avatar_url, :string

      # OAuth provider info
      add :provider, :string, null: false
      # ^ "google" | "github"
      add :provider_id, :string, null: false
      # ^ the unique ID from the provider (sub claim from Google, id from GitHub)

      timestamps(type: :utc_datetime)
    end

    # A user is uniquely identified by their provider + provider_id combination.
    # The same email address could exist across providers as separate accounts.
    create unique_index(:users, [:provider, :provider_id])

    # Fast lookup by email (e.g. for display, search)
    create index(:users, [:email])

    create constraint(:users, :valid_provider, check: "provider IN ('google', 'github')")
  end
end
