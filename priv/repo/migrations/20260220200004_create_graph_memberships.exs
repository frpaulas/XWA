defmodule Xwa.Repo.Migrations.CreateGraphMemberships do
  use Ecto.Migration

  def change do
    create table(:graph_memberships, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :graph_id,
          references(:graphs, type: :uuid, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :uuid, on_delete: :delete_all),
          null: false

      add :role, :string, null: false, default: "viewer"

      timestamps(type: :utc_datetime)
    end

    # A user can only have one membership per graph
    create unique_index(:graph_memberships, [:graph_id, :user_id])
    create index(:graph_memberships, [:user_id])
    create index(:graph_memberships, [:graph_id])

    create constraint(:graph_memberships, :valid_role,
             check: "role IN ('owner', 'editor', 'viewer')"
           )
  end
end
