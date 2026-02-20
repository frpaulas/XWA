defmodule XwaWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  Plug that loads the current user from the session and assigns it to
  `conn.assigns.current_user` and `conn.assigns.current_scope`.

  Should be added to the `:browser` pipeline in the router so every
  request has access to the current user.

  `current_scope` follows the Phoenix 1.8 convention — it is either nil
  (unauthenticated) or a map containing the user:

      %{user: %Xwa.Accounts.User{}}

  LiveViews and templates can pattern-match on `@current_scope` to branch
  between authenticated and unauthenticated states.
  """

  import Plug.Conn
  alias Xwa.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :user_id)

    case user_id && Accounts.get_user(user_id) do
      nil ->
        conn
        |> assign(:current_user, nil)
        |> assign(:current_scope, nil)

      user ->
        scope = %{user: user}

        conn
        |> assign(:current_user, user)
        |> assign(:current_scope, scope)
    end
  end
end
