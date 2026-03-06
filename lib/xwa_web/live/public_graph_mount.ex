defmodule XwaWeb.PublicGraphMount do
  @moduledoc """
  LiveView on_mount hook for public graph routes.

  Loads a graph by owner username + slug from URL params and mounts it
  read-only. If the graph does not exist or is not public the visitor is
  redirected to the graph directory.

  Usage in router:
      live_session :public_graph,
        on_mount: {XwaWeb.PublicGraphMount, :load} do
        live "/graphs/:username/:slug", GraphLive
        live "/graphs/:username/:slug/sources", PublicSourcesLive
      end
  """

  import Phoenix.Component, only: [assign: 3]
  use XwaWeb, :verified_routes

  alias Xwa.Graphs
  alias Xwa.Accounts

  def on_mount(:load, %{"username" => username, "slug" => slug}, _session, socket) do
    case Graphs.get_public_graph_by_slug(username, slug) do
      nil ->
        socket =
          socket
          |> Phoenix.LiveView.put_flash(:error, "Graph not found or not public.")
          |> Phoenix.LiveView.redirect(to: ~p"/graphs")

        {:halt, socket}

      graph_info ->
        owner = Accounts.get_user(graph_info.owner_id)
        graphs = Graphs.list_graphs_for_user(graph_info.owner_id)

        graph = Enum.find(graphs, &(&1.id == graph_info.id))

        scope = %{
          user: owner,
          graph: graph,
          graph_id: graph_info.id,
          role: "viewer",
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
