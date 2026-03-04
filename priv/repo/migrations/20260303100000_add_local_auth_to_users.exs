defmodule Xwa.Repo.Migrations.AddLocalAuthToUsers do
  use Ecto.Migration

  def change do
    # Make email nullable — local users have no email.
    alter table(:users) do
      modify :email, :string, null: true, from: {:string, null: false}
      add :username, :string
      add :password_hash, :string
    end

    create unique_index(:users, [:username])

    # Extend the provider check to include 'local'.
    drop constraint(:users, :valid_provider)
    create constraint(:users, :valid_provider, check: "provider IN ('google', 'github', 'local')")

    # Local users are identified by username, not provider_id. Ensure at least
    # one identifier is always present.
    create constraint(:users, :has_identifier,
      check: "email IS NOT NULL OR username IS NOT NULL"
    )
  end
end
