defmodule XwaWeb.DemoMount do
  @moduledoc """
  LiveView on_mount hook for public demo routes.

  Each demo atom maps to a local username whose graph is shown read-only.
  If the user does not exist, visitors are redirected to the home page.
  """

  import Phoenix.Component, only: [assign: 3]
  use XwaWeb, :verified_routes

  alias Xwa.Accounts
  alias Xwa.Graphs

  # /demo1 → gv2's graph
  def on_mount(:demo1, params, session, socket),
    do: mount_for("gv2", params, session, socket)

  # /demo2 → Jonah's graph
  def on_mount(:demo2, params, session, socket),
    do: mount_for("Jonah", params, session, socket)

  defp mount_for(username, _params, _session, socket) do
    case Accounts.get_user_by_username(username) do
      nil ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:info, "Demo graph not available yet.")
          |> Phoenix.LiveView.redirect(to: ~p"/")

        {:halt, socket}

      user ->
        graphs = Graphs.list_graphs_for_user(user.id)
        graph = List.first(graphs)
        role = graph && Graphs.role_for(graph.id, user.id)

        scope = %{
          user: user,
          graph: graph,
          graph_id: graph && graph.id,
          role: role,
          graphs: graphs
        }

        socket =
          socket
          |> assign(:current_scope, scope)
          |> assign(:read_only, true)

        {:cont, socket}
    end
  end
end
