defmodule XwaWeb.GraphDirectoryLive do
  @moduledoc """
  Public directory of all graphs that have been made public.
  Accessible to unauthenticated visitors.
  """

  use XwaWeb, :live_view

  alias Xwa.Graphs

  @impl true
  def mount(_params, _session, socket) do
    graphs = Graphs.list_public_graphs()

    {:ok,
     socket
     |> assign(:page_title, "Public Graphs")
     |> assign(:graphs, graphs)
     |> assign_new(:current_scope, fn -> nil end)
     |> assign_new(:read_only, fn -> false end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="max-w-3xl mx-auto py-8">
        <div class="mb-8">
          <h1 class="text-3xl font-bold text-base-content">Public Graphs</h1>
          <p class="mt-2 text-base-content/60">
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
