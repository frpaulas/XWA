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
end
