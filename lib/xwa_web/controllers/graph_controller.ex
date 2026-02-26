defmodule XwaWeb.GraphController do
  use XwaWeb, :controller

  alias Xwa.Graphs

  @doc """
  Switches the active graph for the current session and redirects back
  to wherever the user came from (or /graph as fallback).
  """
  def switch(conn, %{"graph_id" => graph_id}) do
    user = conn.assigns.current_scope && conn.assigns.current_scope.user

    if user && Graphs.can_view?(graph_id, user.id) do
      redirect_to = get_req_header(conn, "referer") |> List.first() || ~p"/graph"

      conn
      |> put_session(:graph_id, graph_id)
      |> redirect(external: redirect_to)
    else
      conn
      |> put_flash(:error, "Graph not found or access denied.")
      |> redirect(to: ~p"/graph")
    end
  end
end
