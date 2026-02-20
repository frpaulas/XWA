defmodule Xwa.Graphs.Graph do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "graphs" do
    field :name, :string
    field :description, :string

    belongs_to :organization, Xwa.Accounts.Organization
    has_many :memberships, Xwa.Graphs.GraphMembership
    has_many :members, through: [:memberships, :user]
    has_many :documents, Xwa.Documents.Document

    timestamps(type: :utc_datetime)
  end

  def changeset(graph, attrs) do
    graph
    |> cast(attrs, [:name, :description, :organization_id])
    |> validate_required([:name, :organization_id])
  end
end
