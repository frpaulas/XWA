defmodule Xwa.Repo.Migrations.AddOrganizationIdToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :organization_id,
          references(:organizations, type: :uuid, on_delete: :restrict),
          null: true
    end

    create index(:users, [:organization_id])
  end
end
