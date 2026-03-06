defmodule XwaWeb.PublicSourcesLive do
  @moduledoc """
  Read-only sources list for a public graph.
  Shown at /graphs/:username/:slug/sources.
  """

  use XwaWeb, :live_view

  alias Xwa.Documents

  @impl true
  def mount(_params, _session, socket) do
    graph_id = socket.assigns.current_scope.graph_id
    documents = if graph_id, do: Documents.list_documents_for_graph(graph_id), else: []

    {:ok,
     socket
     |> assign(:documents, documents)
     |> assign(:page_title, "Sources")
     |> assign_new(:viewer, fn -> nil end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} read_only={true} viewer={@viewer}>
      <div class="max-w-3xl mx-auto py-8">
        <div class="mb-6 flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-base-content">
              Sources — {@current_scope.graph && @current_scope.graph.name || "Graph"}
            </h1>
            <p class="text-sm text-base-content/50 mt-1">
              Documents ingested into this knowledge graph.
            </p>
          </div>
          <.link
            navigate={~p"/graphs/#{@current_scope.user.username}/#{@current_scope.graph && @current_scope.graph.slug}"}
            class="btn btn-sm btn-ghost gap-1.5"
          >
            <.icon name="hero-share" class="w-4 h-4" /> View graph
          </.link>
        </div>

        <%= if @documents == [] do %>
          <div class="rounded-xl border border-base-200 bg-base-100 px-8 py-12 text-center">
            <p class="text-base-content/50">No documents yet.</p>
          </div>
        <% else %>
          <div class="flex flex-col gap-2">
            <%= for doc <- @documents do %>
              <div class="flex items-center justify-between rounded-xl border border-base-200 bg-base-100 px-5 py-3.5">
                <div class="min-w-0 flex-1">
                  <p class="text-sm font-medium text-base-content truncate">{doc.title}</p>
                  <p class="text-xs text-base-content/40 mt-0.5">
                    {doc.content_type} · {doc.ingestion_status}
                  </p>
                </div>
                <span class={[
                  "shrink-0 ml-4 inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
                  case doc.ingestion_status do
                    "complete"   -> "bg-success/10 text-success"
                    "processing" -> "bg-warning/10 text-warning"
                    "failed"     -> "bg-error/10 text-error"
                    _            -> "bg-base-200 text-base-content/50"
                  end
                ]}>
                  {doc.ingestion_status}
                </span>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
