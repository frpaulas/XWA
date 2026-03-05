defmodule XwaWeb.LocalSessionController do
  use XwaWeb, :controller

  alias Xwa.Accounts

  @doc "Show the local login form."
  def new(conn, _params) do
    render(conn, :new)
  end

  @doc "Authenticate with username + password and create a session."
  def create(conn, %{"username" => username, "password" => password}) do
    case Accounts.authenticate_local_user(username, password) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> configure_session(renew: true)
        |> put_flash(:info, "Welcome, #{user.name || user.username}!")
        |> redirect(to: ~p"/")

      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, "Invalid username or password.")
        |> render(:new)
    end
  end

  @doc "Show the registration form."
  def register(conn, _params) do
    render(conn, :register)
  end

  @doc "Create a new local user account and sign them in."
  def register_create(conn, %{"username" => username, "password" => password, "password_confirmation" => confirmation}) do
    if password != confirmation do
      conn
      |> put_flash(:error, "Passwords do not match.")
      |> render(:register)
    else
      case Accounts.create_local_user(username, password) do
        {:ok, user} ->
          conn
          |> put_session(:user_id, user.id)
          |> configure_session(renew: true)
          |> put_flash(:info, "Account created. Welcome, #{user.name || user.username}!")
          |> redirect(to: ~p"/")

        {:error, changeset} ->
          errors = Enum.map_join(changeset.errors, ", ", fn {f, {msg, _}} -> "#{f} #{msg}" end)
          conn
          |> put_flash(:error, "Could not create account: #{errors}")
          |> render(:register)
      end
    end
  end
end
