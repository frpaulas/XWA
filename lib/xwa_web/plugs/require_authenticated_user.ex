defmodule XwaWeb.Plugs.RequireAuthenticatedUser do
  @moduledoc """
  Plug that redirects unauthenticated requests to the home page.

  Used as an `on_mount` hook for LiveView live_sessions that require auth.
  Also usable as a regular Plug in controller pipelines.
  """

  import Plug.Conn
  import Phoenix.Controller
  use XwaWeb, :verified_routes

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:current_scope] do
      conn
    else
      conn
      |> put_flash(:error, "You must be signed in to access that page.")
      |> redirect(to: ~p"/")
      |> halt()
    end
  end

  @doc """
  LiveView on_mount hook. Attach to a live_session to protect all LiveViews within it.
  """
  def on_mount(:require_authenticated, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "You must be signed in to access that page.")
        |> Phoenix.LiveView.redirect(to: ~p"/")

      {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      user_id = session["user_id"]
      graph_id = session["graph_id"]

      case user_id && Xwa.Accounts.get_user(user_id) do
        nil -> nil
        user -> build_scope(user, graph_id)
      end
    end)
  end

  defp build_scope(user, session_graph_id) do
    graphs = Xwa.Graphs.list_graphs_for_user(user.id)

    graph =
      if session_graph_id do
        Enum.find(graphs, fn g -> g.id == session_graph_id end) || List.first(graphs)
      else
        List.first(graphs)
      end

    role = graph && Xwa.Graphs.role_for(graph.id, user.id)

    %{
      user: user,
      graph: graph,
      graph_id: graph && graph.id,
      role: role
    }
  end
end
