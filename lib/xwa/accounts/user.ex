defmodule Xwa.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(google github)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :email, :string
    field :name, :string
    field :avatar_url, :string
    field :provider, :string
    field :provider_id, :string
    field :role, :string, default: "user"

    belongs_to :organization, Xwa.Accounts.Organization
    has_many :graph_memberships, Xwa.Graphs.GraphMembership
    has_many :graphs, through: [:graph_memberships, :graph]

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a user from an OAuth callback.
  All fields are set by the provider — users never fill this in directly.
  """
  def oauth_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :avatar_url, :provider, :provider_id])
    |> validate_required([:email, :provider, :provider_id])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email address")
    |> validate_inclusion(:provider, @providers)
    |> unique_constraint([:provider, :provider_id],
      name: :users_provider_provider_id_index,
      message: "account already exists"
    )
  end
end
