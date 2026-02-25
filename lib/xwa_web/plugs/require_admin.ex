defmodule XwaWeb.Plugs.RequireAdmin do
  @moduledoc """
  LiveView on_mount hook that requires the current user to have role "admin".
  Redirects to /sources with a flash error if not.
  """

  use XwaWeb, :verified_routes

  def on_mount(:require_admin, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    case socket.assigns.current_scope do
      %{user: %{role: "admin"}} ->
        {:cont, socket}

      nil ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You must be signed in to access that page.")
          |> Phoenix.LiveView.redirect(to: ~p"/")

        {:halt, socket}

      _ ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "You don't have permission to access that page.")
          |> Phoenix.LiveView.redirect(to: ~p"/sources")

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

    %{user: user, graph: graph, graph_id: graph && graph.id, role: role}
  end
end
