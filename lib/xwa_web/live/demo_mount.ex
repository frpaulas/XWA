defmodule XwaWeb.DemoMount do
  @moduledoc """
  LiveView on_mount hook for the public /demo route.

  Loads the "govinfo" local user's graph scope and marks the socket as
  read_only so the GraphLive template hides all write actions.

  If the govinfo user does not exist, visitors are redirected to the home
  page with an informational flash.
  """

  import Phoenix.Component, only: [assign: 3]
  use XwaWeb, :verified_routes

  alias Xwa.Accounts
  alias Xwa.Graphs

  def on_mount(:demo, _params, _session, socket) do
    case Accounts.get_user_by_username("govinfo") do
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
