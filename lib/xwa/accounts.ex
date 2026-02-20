defmodule Xwa.Accounts do
  @moduledoc """
  Context for managing user accounts.

  Users are created exclusively through OAuth providers (Google, GitHub).
  There are no passwords — authentication is entirely delegated to the provider.

  ## Find or create pattern

  On every successful OAuth callback, `find_or_create_from_oauth/1` is called
  with the `Ueberauth.Auth` struct. If a user with that provider + provider_id
  already exists, they are returned as-is. If not, a new user record is created.

  This means a user who signs in with Google and a user who signs in with GitHub
  using the same email address are treated as two separate accounts. This is
  intentional — email addresses are not reliable cross-provider identifiers.
  """

  require Logger

  alias Xwa.Repo
  alias Xwa.Accounts.User
  alias Xwa.Graphs

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Gets a user by id. Returns nil if not found.
  """
  def get_user(id), do: Repo.get(User, id)

  @doc """
  Gets a user by id. Raises if not found.
  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Finds a user by provider and provider_id.
  Returns nil if not found.
  """
  def get_user_by_provider(provider, provider_id)
      when is_binary(provider) and is_binary(provider_id) do
    Repo.get_by(User, provider: provider, provider_id: provider_id)
  end

  # ---------------------------------------------------------------------------
  # OAuth
  # ---------------------------------------------------------------------------

  @doc """
  Finds an existing user or creates a new one from an `Ueberauth.Auth` struct.

  Returns `{:ok, user}` on success or `{:error, changeset}` on failure.

  This is the single entry point for the OAuth authentication flow. Call it
  from the auth controller after Ueberauth has successfully authenticated the user.
  """
  @spec find_or_create_from_oauth(Ueberauth.Auth.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create_from_oauth(%Ueberauth.Auth{} = auth) do
    provider = to_string(auth.provider)
    provider_id = to_string(auth.uid)

    attrs = %{
      provider: provider,
      provider_id: provider_id,
      email: email_from_auth(auth),
      name: name_from_auth(auth),
      avatar_url: avatar_from_auth(auth)
    }

    case get_user_by_provider(provider, provider_id) do
      nil ->
        with {:ok, user} <-
               %User{}
               |> User.oauth_changeset(attrs)
               |> Repo.insert() do
          case Graphs.bootstrap_for_user(user) do
            {:ok, _} ->
              {:ok, user}

            {:error, step, changeset, _} ->
              Logger.error(
                "[Accounts] Failed to bootstrap graph for new user #{user.id} at step #{step}: #{inspect(changeset)}"
              )
              # Return the user anyway — they can still log in, bootstrap can be retried
              {:ok, user}
          end
        end

      existing_user ->
        # Update mutable fields (name, avatar) in case they changed at the provider
        existing_user
        |> User.oauth_changeset(attrs)
        |> Repo.update()
    end
  end

  # ---------------------------------------------------------------------------
  # Private — field extraction from Ueberauth.Auth
  # ---------------------------------------------------------------------------

  defp email_from_auth(%Ueberauth.Auth{info: info}) do
    info.email
  end

  defp name_from_auth(%Ueberauth.Auth{info: info}) do
    cond do
      info.name && info.name != "" ->
        info.name

      info.first_name || info.last_name ->
        [info.first_name, info.last_name]
        |> Enum.filter(& &1)
        |> Enum.join(" ")

      info.nickname ->
        info.nickname

      true ->
        nil
    end
  end

  defp avatar_from_auth(%Ueberauth.Auth{info: info}) do
    info.image
  end
end
