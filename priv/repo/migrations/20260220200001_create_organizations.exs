defmodule Xwa.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  def change do
    create table(:organizations, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :string, null: false
      add :plan, :string, null: false, default: "free"

      timestamps(type: :utc_datetime)
    end

    create constraint(:organizations, :valid_plan,
             check: "plan IN ('free', 'pro', 'enterprise')"
           )
  end
end
