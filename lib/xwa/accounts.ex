defmodule Xwa.Accounts do
  @moduledoc """
  Context for managing user accounts.

  Supports two authentication modes:

  * **OAuth** (Google, GitHub) — `find_or_create_from_oauth/1`
  * **Local** (username + bcrypt password) — `create_local_user/2` / `authenticate_local_user/2`

  OAuth users have no password; local users have no email.
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

  @doc """
  Finds a local user by username. Returns nil if not found.
  """
  def get_user_by_username(username) when is_binary(username) do
    Repo.get_by(User, username: username, provider: "local")
  end

  @doc """
  Sets (or updates) a username on a user. Used for OAuth users choosing a username post-signup.
  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  @spec set_username(User.t(), String.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_username(%User{} = user, username) do
    user
    |> User.username_changeset(%{username: username})
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Local auth
  # ---------------------------------------------------------------------------

  @doc """
  Creates a local user with a username and plain-text password.
  The password is hashed before storage. Bootstraps a graph on success.
  """
  @spec create_local_user(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def create_local_user(username, password) do
    attrs = %{username: username, name: username, password: password}

    with {:ok, user} <-
           %User{}
           |> User.local_changeset(attrs)
           |> Repo.insert() do
      case Graphs.bootstrap_for_user(user) do
        {:ok, _} ->
          {:ok, user}

        {:error, step, changeset, _} ->
          Logger.error(
            "[Accounts] Failed to bootstrap graph for local user #{user.id} at step #{step}: #{inspect(changeset)}"
          )
          {:ok, user}
      end
    end
  end

  @doc """
  Authenticates a local user by username and plain-text password.
  Returns `{:ok, user}` on success, `{:error, :invalid_credentials}` otherwise.
  """
  @spec authenticate_local_user(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :invalid_credentials}
  def authenticate_local_user(username, password)
      when is_binary(username) and is_binary(password) do
    user = get_user_by_username(username)

    if user && Bcrypt.verify_pass(password, user.password_hash) do
      {:ok, user}
    else
      # Run a dummy check to avoid timing attacks even when user is nil.
      Bcrypt.no_user_verify()
      {:error, :invalid_credentials}
    end
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
