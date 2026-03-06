defmodule Xwa.Repo.Migrations.AddPublicAndSlugToGraphs do
  use Ecto.Migration

  def change do
    alter table(:graphs) do
      add :public, :boolean, default: false, null: false
      add :slug, :string, size: 255
    end

    create unique_index(:graphs, [:organization_id, :slug],
      name: :graphs_organization_id_slug_index
    )
  end
end
