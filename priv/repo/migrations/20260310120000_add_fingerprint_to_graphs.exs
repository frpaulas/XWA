defmodule Xwa.Repo.Migrations.AddFingerprintToGraphs do
  use Ecto.Migration

  def change do
    alter table(:graphs) do
      add :fingerprint, :map
    end
  end
end
