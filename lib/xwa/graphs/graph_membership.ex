defmodule Xwa.Graphs.GraphMembership do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(owner editor viewer)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "graph_memberships" do
    field :role, :string, default: "viewer"

    belongs_to :graph, Xwa.Graphs.Graph
    belongs_to :user, Xwa.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:graph_id, :user_id, :role])
    |> validate_required([:graph_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:graph_id, :user_id],
      name: :graph_memberships_graph_id_user_id_index,
      message: "user is already a member of this graph"
    )
  end
end
