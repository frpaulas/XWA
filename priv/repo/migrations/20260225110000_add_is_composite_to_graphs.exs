defmodule Xwa.Repo.Migrations.AddIsCompositeToGraphs do
  use Ecto.Migration

  def change do
    alter table(:graphs) do
      add :is_composite, :boolean, null: false, default: false
    end
  end
end
