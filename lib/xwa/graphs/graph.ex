defmodule Xwa.Graphs.Graph do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "graphs" do
    field :name, :string
    field :description, :string
    field :is_composite, :boolean, default: false

    belongs_to :organization, Xwa.Accounts.Organization
    has_many :memberships, Xwa.Graphs.GraphMembership
    has_many :members, through: [:memberships, :user]
    has_many :documents, Xwa.Documents.Document

    # Composite graph relationships
    has_many :source_subscriptions, Xwa.Graphs.GraphSubscription,
      foreign_key: :composite_graph_id

    has_many :source_graphs, through: [:source_subscriptions, :source_graph]

    has_many :composite_subscriptions, Xwa.Graphs.GraphSubscription,
      foreign_key: :source_graph_id

    has_many :composite_graphs, through: [:composite_subscriptions, :composite_graph]

    timestamps(type: :utc_datetime)
  end

  def changeset(graph, attrs) do
    graph
    |> cast(attrs, [:name, :description, :organization_id, :is_composite])
    |> validate_required([:name, :organization_id])
  end
end
