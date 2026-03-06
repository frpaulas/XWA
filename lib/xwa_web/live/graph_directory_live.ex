defmodule XwaWeb.GraphDirectoryLive do
  @moduledoc """
  Public directory of all graphs that have been made public.
  Accessible to unauthenticated visitors.
  """

  use XwaWeb, :live_view

  alias Xwa.{Accounts, Graphs}

  @impl true
  def mount(_params, session, socket) do
    graphs = Graphs.list_public_graphs()
    current_scope = build_scope_from_session(session)

    {:ok,
     socket
     |> assign(:page_title, "Public Graphs")
     |> assign(:graphs, graphs)
     |> assign(:current_scope, current_scope)
     |> assign(:read_only, false)}
  end

  defp build_scope_from_session(session) do
    with user_id when not is_nil(user_id) <- session["user_id"],
         user when not is_nil(user) <- Accounts.get_user(user_id) do
      graph_id = session["graph_id"]
      graphs = Graphs.list_graphs_for_user(user.id)

      graph =
        if graph_id,
          do: Enum.find(graphs, &(&1.id == graph_id)) || List.first(graphs),
          else: List.first(graphs)

      %{
        user: user,
        graph: graph,
        graph_id: graph && graph.id,
        role: graph && Graphs.role_for(graph.id, user.id),
        graphs: graphs
      }
    else
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-3xl mx-auto py-8">
        <%= if @current_scope do %>
          <div class="mb-10">
            <h2 class="text-xl font-bold text-base-content mb-4">Your Graphs</h2>
            <%= if @current_scope.graphs == [] do %>
              <div class="rounded-xl border border-base-200 bg-base-100 px-8 py-8 text-center">
                <p class="text-base-content/50">You have no graphs yet.</p>
              </div>
            <% else %>
              <div class="flex flex-col gap-3">
                <%= for g <- @current_scope.graphs do %>
                  <.link
                    navigate={~p"/graph"}
                    class="group flex flex-col gap-1 rounded-xl border border-base-200 bg-base-100 px-6 py-4 hover:border-primary/50 hover:bg-base-200/50 transition-all"
                  >
                    <div class="flex items-center justify-between">
                      <h2 class="text-base font-semibold text-base-content group-hover:text-primary transition-colors">
                        {g.name}
                      </h2>
                      <%= if g.id == @current_scope.graph_id do %>
                        <span class="text-xs text-primary font-medium">active</span>
                      <% end %>
                    </div>
                  </.link>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <div class="mb-8">
          <h1 class="text-xl font-bold text-base-content mb-1">Public Graphs</h1>
          <p class="text-sm text-base-content/60">
            Browse publicly shared knowledge graphs. No sign-in required.
          </p>
        </div>

        <%= if @graphs == [] do %>
          <div class="rounded-xl border border-base-200 bg-base-100 px-8 py-12 text-center">
            <p class="text-base-content/50">No public graphs yet.</p>
          </div>
        <% else %>
          <div class="flex flex-col gap-3">
            <%= for g <- @graphs do %>
              <.link
                navigate={~p"/graphs/#{g.username}/#{g.slug}"}
                class="group flex flex-col gap-1 rounded-xl border border-base-200 bg-base-100 px-6 py-4 hover:border-primary/50 hover:bg-base-200/50 transition-all"
              >
                <div class="flex items-center justify-between">
                  <h2 class="text-base font-semibold text-base-content group-hover:text-primary transition-colors">
                    {g.name}
                  </h2>
                  <span class="text-xs text-base-content/40 font-mono">@{g.username}</span>
                </div>
                <%= if g.description && g.description != "" do %>
                  <p class="text-sm text-base-content/60 line-clamp-2">{g.description}</p>
                <% end %>
                <p class="text-xs text-base-content/30">
                  /graphs/{g.username}/{g.slug}
                </p>
              </.link>
            <% end %>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
