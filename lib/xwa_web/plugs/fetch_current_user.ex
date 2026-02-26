defmodule XwaWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  Plug that loads the current user from the session and assigns it to
  `conn.assigns.current_user` and `conn.assigns.current_scope`.

  Should be added to the `:browser` pipeline in the router so every
  request has access to the current user.

  `current_scope` follows the Phoenix 1.8 convention — it is either nil
  (unauthenticated) or a map containing:

      %{
        user:     %Xwa.Accounts.User{},
        graph:    %Xwa.Graphs.Graph{},   # active graph (nil if none yet)
        graph_id: "uuid-string",          # convenience accessor
        role:     "owner" | "editor" | "viewer" | nil
      }

  The active graph is selected by the `:graph_id` session key if set and
  the user is still a member, otherwise falls back to their first graph.
  """

  import Plug.Conn
  alias Xwa.Accounts
  alias Xwa.Graphs

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :user_id)

    case user_id && Accounts.get_user(user_id) do
      nil ->
        conn
        |> assign(:current_user, nil)
        |> assign(:current_scope, nil)

      user ->
        graph_id = get_session(conn, :graph_id)
        scope = build_scope(user, graph_id)

        conn
        |> assign(:current_user, user)
        |> assign(:current_scope, scope)
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_scope(user, session_graph_id) do
    graphs = Graphs.list_graphs_for_user(user.id)

    graph =
      cond do
        session_graph_id ->
          Enum.find(graphs, fn g -> g.id == session_graph_id end) ||
            List.first(graphs)

        true ->
          List.first(graphs)
      end

    role = graph && Graphs.role_for(graph.id, user.id)

    %{
      user: user,
      graph: graph,
      graph_id: graph && graph.id,
      role: role,
      graphs: graphs
    }
  end
end
