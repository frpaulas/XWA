defmodule Xwa.Repo.Migrations.AddGraphIdToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add :graph_id,
          references(:graphs, type: :uuid, on_delete: :restrict),
          null: true
    end

    create index(:documents, [:graph_id])
  end
end
