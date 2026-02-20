defmodule Xwa.Accounts.UserKey do
  use Ecto.Schema
  import Ecto.Changeset

  @valid_tiers ~w(user)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "user_keys" do
    belongs_to :user, Xwa.Accounts.User

    # The user's raw 32-byte key, encrypted with the app-level ENCRYPTION_KEY.
    # Wire format: <<iv::binary-12, tag::binary-16, ciphertext::binary-32>>
    # Total: 60 bytes on disk.
    field :encrypted_key, :binary

    # "user" for now; reserved for future key tiers
    field :tier, :string, default: "user"

    timestamps(type: :utc_datetime)
  end

  def changeset(user_key, attrs) do
    user_key
    |> cast(attrs, [:user_id, :encrypted_key, :tier])
    |> validate_required([:user_id, :encrypted_key, :tier])
    |> validate_inclusion(:tier, @valid_tiers)
    |> unique_constraint([:user_id, :tier])
    |> assoc_constraint(:user)
  end
end
