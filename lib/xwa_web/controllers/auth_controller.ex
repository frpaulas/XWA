defmodule XwaWeb.AuthController do
  use XwaWeb, :controller

  plug Ueberauth

  alias Xwa.Accounts

  @doc """
  Handles OAuth callbacks from providers.

  Dispatches on the ueberauth assign:
  - `ueberauth_failure` — provider returned an error or the user denied access
  - `ueberauth_auth`   — successful authentication; finds or creates the user
  """
  def callback(conn, params)

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    reason =
      case failure.errors do
        [%{message: msg} | _] -> msg
        _ -> "Authentication failed. Please try again."
      end

    conn
    |> put_flash(:error, reason)
    |> redirect(to: ~p"/")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case Accounts.find_or_create_from_oauth(auth) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> configure_session(renew: true)
        |> put_flash(:info, "Welcome, #{user.name || user.email}!")
        |> redirect(to: ~p"/")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "There was a problem signing you in. Please try again.")
        |> redirect(to: ~p"/")
    end
  end

  @doc """
  Clears the session and redirects to the home page.
  """
  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "You have been signed out.")
    |> redirect(to: ~p"/")
  end
end
