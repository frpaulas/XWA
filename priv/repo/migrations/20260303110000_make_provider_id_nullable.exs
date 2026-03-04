defmodule Xwa.Repo.Migrations.MakeProviderIdNullable do
  use Ecto.Migration

  def change do
    alter table(:users) do
      modify :provider_id, :string, null: true, from: {:string, null: false}
    end
  end
end
