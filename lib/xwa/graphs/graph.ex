defmodule Xwa.Graphs.Graph do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "graphs" do
    field :name, :string
    field :description, :string
    field :is_composite, :boolean, default: false
    field :public, :boolean, default: false
    field :slug, :string

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

  @doc """
  Changeset for updating graph settings (name, description, public visibility).
  Derives slug from name. Requires name if making public.
  """
  def settings_changeset(graph, attrs) do
    graph
    |> cast(attrs, [:name, :description, :public])
    |> validate_length(:name, max: 120)
    |> validate_public_requires_name()
    |> maybe_generate_slug()
    |> unique_constraint([:organization_id, :slug],
      name: :graphs_organization_id_slug_index,
      message: "slug already taken in this organization"
    )
  end

  defp validate_public_requires_name(changeset) do
    public = get_field(changeset, :public)
    name = get_field(changeset, :name)

    if public and (is_nil(name) or String.trim(name) == "") do
      add_error(changeset, :name, "is required before making a graph public")
    else
      changeset
    end
  end

  defp maybe_generate_slug(changeset) do
    case get_change(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :slug, slugify(name))
    end
  end

  @doc "Converts a graph name to a URL-safe slug."
  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/\s+/, "-")
    |> String.replace(~r/-{2,}/, "-")
    |> String.trim("-")
    |> String.slice(0, 100)
  end
end
