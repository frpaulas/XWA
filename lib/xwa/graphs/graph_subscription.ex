defmodule Xwa.Graphs.GraphSubscription do
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(co-owner contributor observer)
  @statuses ~w(pending active revoked)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "graph_subscriptions" do
    belongs_to :composite_graph, Xwa.Graphs.Graph
    belongs_to :source_graph, Xwa.Graphs.Graph
    belongs_to :invited_by_user, Xwa.Accounts.User, foreign_key: :invited_by

    field :role, :string, default: "co-owner"
    field :status, :string, default: "pending"

    timestamps(type: :utc_datetime)
  end

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, [:composite_graph_id, :source_graph_id, :role, :status, :invited_by])
    |> validate_required([:composite_graph_id, :source_graph_id, :role, :status])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:composite_graph_id, :source_graph_id])
  end
end
