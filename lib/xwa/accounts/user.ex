defmodule Xwa.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(google github local)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :email, :string
    field :name, :string
    field :avatar_url, :string
    field :provider, :string
    field :provider_id, :string
    field :role, :string, default: "user"
    field :username, :string
    field :password_hash, :string
    # Virtual field — only populated during authentication, never persisted.
    field :password, :string, virtual: true

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

  @doc """
  Changeset for creating a local (username + password) user.
  """
  def local_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :name, :password])
    |> validate_required([:username, :password])
    |> validate_length(:username, min: 2, max: 40)
    |> validate_length(:password, min: 6)
    |> unique_constraint(:username)
    |> put_change(:provider, "local")
    |> put_password_hash()
  end

  defp put_password_hash(%Ecto.Changeset{valid?: true, changes: %{password: pw}} = cs) do
    put_change(cs, :password_hash, Bcrypt.hash_pwd_salt(pw))
  end

  defp put_password_hash(cs), do: cs
end
