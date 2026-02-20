defmodule Xwa.Repo.Migrations.CreateGraphs do
  use Ecto.Migration

  def change do
    create table(:graphs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :organization_id,
          references(:organizations, type: :uuid, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :description, :text

      timestamps(type: :utc_datetime)
    end

    create index(:graphs, [:organization_id])
  end
end
