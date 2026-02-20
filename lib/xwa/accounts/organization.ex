defmodule Xwa.Accounts.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  @plans ~w(free pro enterprise)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "organizations" do
    field :name, :string
    field :plan, :string, default: "free"

    has_many :users, Xwa.Accounts.User
    has_many :graphs, Xwa.Graphs.Graph

    timestamps(type: :utc_datetime)
  end

  def changeset(org, attrs) do
    org
    |> cast(attrs, [:name, :plan])
    |> validate_required([:name])
    |> validate_inclusion(:plan, @plans)
  end
end
