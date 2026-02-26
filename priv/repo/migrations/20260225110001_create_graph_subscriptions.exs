defmodule Xwa.Repo.Migrations.CreateGraphSubscriptions do
  use Ecto.Migration

  def change do
    create table(:graph_subscriptions, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :composite_graph_id,
          references(:graphs, type: :uuid, on_delete: :delete_all),
          null: false

      add :source_graph_id,
          references(:graphs, type: :uuid, on_delete: :delete_all),
          null: false

      # Role of the source graph's owner within the composite graph
      add :role, :string, null: false, default: "co-owner"

      # Invite lifecycle
      add :status, :string, null: false, default: "pending"

      add :invited_by,
          references(:users, type: :uuid, on_delete: :nilify_all),
          null: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:graph_subscriptions, [:composite_graph_id, :source_graph_id])
    create index(:graph_subscriptions, [:composite_graph_id])
    create index(:graph_subscriptions, [:source_graph_id])
    create index(:graph_subscriptions, [:status])

    create constraint(:graph_subscriptions, :valid_role,
             check: "role IN ('co-owner', 'contributor', 'observer')"
           )

    create constraint(:graph_subscriptions, :valid_status,
             check: "status IN ('pending', 'active', 'revoked')"
           )

    create constraint(:graph_subscriptions, :no_self_subscription,
             check: "composite_graph_id <> source_graph_id"
           )
  end
end
