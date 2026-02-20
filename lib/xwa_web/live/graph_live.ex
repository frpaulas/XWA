defmodule XwaWeb.GraphLive do
  use XwaWeb, :live_view

  alias Xwa.Graph.{Nodes, Edges}
  alias Xwa.Documents

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_scope.user.id
    graph_id = socket.assigns.current_scope.graph_id
    {:ok, nodes} = Nodes.list(graph_id, user_id: user_id)
    {:ok, all_edges} = all_edges(graph_id, user_id)

    socket =
      socket
      |> assign(:selected_node, nil)
      |> assign(:filter_layer, "all")
      |> assign(:filter_type, "all")
      |> assign(:search, "")
      |> assign(:nodes, nodes)
      |> assign(:all_edges, all_edges)
      |> assign(:graph_data, build_graph_data(nodes, all_edges))
      |> assign(:connect_from, nil)
      |> assign(:new_edge_modal, nil)
      |> assign(:confirm_delete_edge, nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("node_selected", %{"id" => node_id}, socket) when is_nil(socket.assigns.connect_from) do
    node = Enum.find(socket.assigns.nodes, &(&1.id == node_id))

    selected =
      if node do
        doc =
          if node.source_document_id,
            do: Documents.get_document(node.source_document_id),
            else: nil

        node_edges =
          socket.assigns.all_edges
          |> Enum.filter(&(&1.from_node_id == node_id or &1.to_node_id == node_id))
          |> Enum.map(fn e ->
            other_id = if e.from_node_id == node_id, do: e.to_node_id, else: e.from_node_id
            direction = if e.from_node_id == node_id, do: :out, else: :in
            other = Enum.find(socket.assigns.nodes, &(&1.id == other_id))
            other_label = other && (other.summary || other.content) || other_id
            Map.from_struct(e) |> Map.merge(%{other_label: other_label, direction: direction})
          end)

        Map.from_struct(node) |> Map.put(:source_document, doc) |> Map.put(:edges, node_edges)
      end

    {:noreply, assign(socket, selected_node: selected, confirm_delete_edge: nil)}
  end

  def handle_event("deselect", _params, socket) do
    {:noreply, assign(socket, selected_node: nil, connect_from: nil, new_edge_modal: nil, confirm_delete_edge: nil)}
  end

  def handle_event("start_connect", _params, socket) do
    {:noreply, assign(socket, connect_from: socket.assigns.selected_node.id)}
  end

  def handle_event("cancel_connect", _params, socket) do
    {:noreply, assign(socket, connect_from: nil, new_edge_modal: nil)}
  end

  def handle_event("confirm_delete_edge", %{"id" => edge_id}, socket) do
    {:noreply, assign(socket, confirm_delete_edge: edge_id)}
  end

  def handle_event("cancel_delete_edge", _params, socket) do
    {:noreply, assign(socket, confirm_delete_edge: nil)}
  end

  def handle_event("delete_edge", %{"id" => edge_id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    edge = Enum.find(socket.assigns.all_edges, &(&1.id == edge_id))

    if is_nil(edge) do
      {:noreply, put_flash(socket, :error, "Edge not found")}
    else
      case Edges.hide_for(edge_id, user_id) do
        :ok ->
          all_edges = Enum.reject(socket.assigns.all_edges, &(&1.id == edge_id))
          socket =
            socket
            |> assign(:all_edges, all_edges)
            |> assign(:confirm_delete_edge, nil)
            |> assign(:selected_node, nil)
            |> apply_filters(socket.assigns.filter_layer, socket.assigns.filter_type, socket.assigns.search)

          {:noreply, put_flash(socket, :info, "Edge hidden")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to hide edge: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("node_selected", %{"id" => node_id}, socket) when socket.assigns.connect_from != nil do
    from_id = socket.assigns.connect_from

    if node_id == from_id do
      {:noreply, socket}
    else
      from_node = Enum.find(socket.assigns.nodes, &(&1.id == from_id))
      to_node = Enum.find(socket.assigns.nodes, &(&1.id == node_id))

      modal = %{
        from_id: from_id,
        to_id: node_id,
        from_label: (from_node && (from_node.summary || from_node.content)) || from_id,
        to_label: (to_node && (to_node.summary || to_node.content)) || node_id,
        type: "relates",
        certainty: "solid"
      }

      {:noreply, assign(socket, new_edge_modal: modal, connect_from: nil)}
    end
  end

  def handle_event("create_edge", params, socket) do
    user_id = socket.assigns.current_scope.user.id
    modal = socket.assigns.new_edge_modal

    attrs = %{
      from_node_id: modal.from_id,
      to_node_id: modal.to_id,
      type: String.trim(params["type"] || "relates"),
      certainty: params["certainty"] || "solid",
      confidence: 1.0,
      ai_inferred: false,
      human_validated: true,
      created_by: user_id
    }

    case Edges.create(attrs) do
      {:ok, new_edge} ->
        all_edges = [new_edge | socket.assigns.all_edges]
        socket =
          socket
          |> assign(:all_edges, all_edges)
          |> assign(:new_edge_modal, nil)
          |> assign(:connect_from, nil)
          |> apply_filters(socket.assigns.filter_layer, socket.assigns.filter_type, socket.assigns.search)
        |> assign(:selected_node, nil)

        {:noreply, put_flash(socket, :info, "Edge created")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create edge: #{inspect(reason)}")}
    end
  end

  def handle_event("filter_layer", %{"layer" => layer}, socket) do
    socket = apply_filters(socket, layer, socket.assigns.filter_type, socket.assigns.search)
    {:noreply, socket}
  end

  def handle_event("filter_type", %{"type" => type}, socket) do
    socket = apply_filters(socket, socket.assigns.filter_layer, type, socket.assigns.search)
    {:noreply, socket}
  end

  def handle_event("search", %{"q" => q}, socket) do
    socket = apply_filters(socket, socket.assigns.filter_layer, socket.assigns.filter_type, q)
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp all_edges(graph_id, user_id) do
    Edges.list(graph_id, user_id)
  end

  defp apply_filters(socket, layer, type, search) do
    nodes = socket.assigns.nodes

    filtered =
      nodes
      |> filter_by_layer(layer)
      |> filter_by_type(type)
      |> filter_by_search(search)

    # Only include edges where both endpoints are in the filtered set
    node_ids = MapSet.new(filtered, & &1.id)

    filtered_edges =
      Enum.filter(socket.assigns.all_edges, fn e ->
        MapSet.member?(node_ids, e.from_node_id) and
          MapSet.member?(node_ids, e.to_node_id)
      end)

    socket
    |> assign(:filter_layer, layer)
    |> assign(:filter_type, type)
    |> assign(:search, search)
    |> assign(:graph_data, build_graph_data(filtered, filtered_edges))
  end

  defp filter_by_layer(nodes, "all"), do: nodes
  defp filter_by_layer(nodes, layer), do: Enum.filter(nodes, &(&1.corpus_layer == layer))

  defp filter_by_type(nodes, "all"), do: nodes
  defp filter_by_type(nodes, type), do: Enum.filter(nodes, &(&1.type == type))

  defp filter_by_search(nodes, ""), do: nodes
  defp filter_by_search(nodes, q) do
    q = String.downcase(q)
    Enum.filter(nodes, fn n ->
      String.contains?(String.downcase(n.summary || ""), q) or
        String.contains?(String.downcase(n.content || ""), q)
    end)
  end

  defp build_graph_data(nodes, edges) do
    cy_nodes =
      Enum.map(nodes, fn n ->
        %{
          data: %{
            id: n.id,
            label: n.summary || n.content,
            type: n.type || "unknown",
            corpus_layer: n.corpus_layer || "unknown",
            confidence: n.confidence || 1.0,
            human_validated: n.human_validated || false,
            contested: n.contested || false
          }
        }
      end)

    cy_edges =
      Enum.map(edges, fn e ->
        %{
          data: %{
            id: e.id,
            source: e.from_node_id,
            target: e.to_node_id,
            type: e.type || "relates",
            certainty: e.certainty || "dashed",
            confidence: e.confidence || 0.5
          }
        }
      end)

    %{nodes: cy_nodes, edges: cy_edges}
  end

  defp node_types(nodes) do
    nodes
    |> Enum.map(& &1.type)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp corpus_layer_label("self_description"), do: "Self-description"
  defp corpus_layer_label("internal_record"), do: "Internal record"
  defp corpus_layer_label("external_context"), do: "External context"
  defp corpus_layer_label(other), do: other || "Unknown"

  defp layer_dot_class("self_description"), do: "bg-primary"
  defp layer_dot_class("internal_record"), do: "bg-secondary"
  defp layer_dot_class("external_context"), do: "bg-accent"
  defp layer_dot_class(_), do: "bg-base-400"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :node_types, node_types(assigns.nodes))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex h-[calc(100vh-4rem)] -mx-4 -my-6 overflow-hidden">

        <%!-- Left sidebar: filters --%>
        <div class="w-56 shrink-0 border-r border-base-200 bg-base-100 flex flex-col overflow-y-auto">
          <div class="px-4 py-4 border-b border-base-200">
            <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/50 mb-3">Filter</h2>

            <%!-- Search --%>
            <div class="relative mb-4">
              <.icon name="hero-magnifying-glass" class="absolute left-2.5 top-2.5 w-3.5 h-3.5 text-base-content/40" />
              <input
                type="text"
                placeholder="Search claims…"
                value={@search}
                phx-change="search"
                phx-debounce="300"
                name="q"
                class="w-full rounded-lg border border-base-300 bg-base-200/50 pl-8 pr-3 py-2 text-xs text-base-content placeholder:text-base-content/35 focus:border-primary focus:outline-none focus:ring-1 focus:ring-primary transition-colors"
              />
            </div>

            <%!-- Corpus layer --%>
            <p class="text-xs font-medium text-base-content/50 mb-1.5">Corpus layer</p>
            <div class="space-y-1 mb-4">
              <%= for {label, value} <- [{"All layers", "all"}, {"Self-description", "self_description"}, {"Internal record", "internal_record"}, {"External context", "external_context"}] do %>
                <button
                  phx-click="filter_layer"
                  phx-value-layer={value}
                  class={[
                    "w-full text-left px-2.5 py-1.5 rounded-lg text-xs transition-colors",
                    if(@filter_layer == value,
                      do: "bg-primary/10 text-primary font-medium",
                      else: "text-base-content/60 hover:bg-base-200 hover:text-base-content"
                    )
                  ]}
                >
                  {label}
                </button>
              <% end %>
            </div>

            <%!-- Claim type --%>
            <%= if @node_types != [] do %>
              <p class="text-xs font-medium text-base-content/50 mb-1.5">Claim type</p>
              <div class="space-y-1">
                <button
                  phx-click="filter_type"
                  phx-value-type="all"
                  class={[
                    "w-full text-left px-2.5 py-1.5 rounded-lg text-xs transition-colors",
                    if(@filter_type == "all",
                      do: "bg-primary/10 text-primary font-medium",
                      else: "text-base-content/60 hover:bg-base-200 hover:text-base-content"
                    )
                  ]}
                >
                  All types
                </button>
                <%= for type <- @node_types do %>
                  <button
                    phx-click="filter_type"
                    phx-value-type={type}
                    class={[
                      "w-full text-left px-2.5 py-1.5 rounded-lg text-xs capitalize transition-colors",
                      if(@filter_type == type,
                        do: "bg-primary/10 text-primary font-medium",
                        else: "text-base-content/60 hover:bg-base-200 hover:text-base-content"
                      )
                    ]}
                  >
                    {type}
                  </button>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Legend --%>
          <div class="px-4 py-4 mt-auto border-t border-base-200">
            <p class="text-xs font-medium text-base-content/50 mb-2">Legend</p>
            <div class="space-y-1.5">
              <%= for layer <- ["self_description", "internal_record", "external_context"] do %>
                <div class="flex items-center gap-2">
                  <div class={["w-2.5 h-2.5 rounded-full shrink-0", layer_dot_class(layer)]}></div>
                  <span class="text-xs text-base-content/60">{corpus_layer_label(layer)}</span>
                </div>
              <% end %>
              <div class="pt-1.5 border-t border-base-200 mt-1.5 space-y-1.5">
                <div class="flex items-center gap-2">
                  <div class="w-5 border-t-2 border-base-content/60 shrink-0"></div>
                  <span class="text-xs text-base-content/60">Solid</span>
                </div>
                <div class="flex items-center gap-2">
                  <div class="w-5 border-t-2 border-dashed border-base-content/40 shrink-0"></div>
                  <span class="text-xs text-base-content/60">Dashed</span>
                </div>
                <div class="flex items-center gap-2">
                  <div class="w-5 border-t-2 border-dotted border-base-content/25 shrink-0"></div>
                  <span class="text-xs text-base-content/60">Dotted</span>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- New edge modal --%>
        <%= if @new_edge_modal do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
            <div class="bg-base-100 rounded-2xl shadow-2xl w-full max-w-sm p-6">
              <h3 class="text-base font-semibold text-base-content mb-1">New edge</h3>
              <p class="text-xs text-base-content/50 mb-4">
                <span class="font-medium text-base-content/70">{@new_edge_modal.from_label}</span>
                <span class="mx-1.5">→</span>
                <span class="font-medium text-base-content/70">{@new_edge_modal.to_label}</span>
              </p>
              <form phx-submit="create_edge" class="space-y-4">
                <div>
                  <label class="block text-xs font-medium text-base-content/60 mb-1">Relationship type</label>
                  <input
                    type="text"
                    name="type"
                    value={@new_edge_modal.type}
                    placeholder="e.g. relates, supports, contradicts…"
                    autofocus
                    class="w-full rounded-lg border border-base-300 bg-base-200/50 px-3 py-2 text-sm focus:border-primary focus:outline-none focus:ring-1 focus:ring-primary"
                  />
                </div>
                <div>
                  <label class="block text-xs font-medium text-base-content/60 mb-1">Certainty</label>
                  <select name="certainty" class="w-full rounded-lg border border-base-300 bg-base-200/50 px-3 py-2 text-sm focus:border-primary focus:outline-none focus:ring-1 focus:ring-primary">
                    <option value="solid">Solid — confident</option>
                    <option value="dashed">Dashed — probable</option>
                    <option value="dotted">Dotted — speculative</option>
                  </select>
                </div>
                <div class="flex justify-end gap-2 pt-1">
                  <button type="button" phx-click="cancel_connect" class="rounded-lg border border-base-300 px-4 py-2 text-sm text-base-content/60 hover:bg-base-200 transition-colors">
                    Cancel
                  </button>
                  <button type="submit" class="rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-content hover:brightness-110 transition-all">
                    Create edge
                  </button>
                </div>
              </form>
            </div>
          </div>
        <% end %>

        <%!-- Main: graph canvas --%>
        <div class="flex-1 relative bg-base-200/30">
          <%= if @graph_data.nodes == [] do %>
            <div class="absolute inset-0 flex flex-col items-center justify-center text-center">
              <div class="flex h-12 w-12 items-center justify-center rounded-xl bg-base-200 mb-4">
                <.icon name="hero-circle-stack" class="w-6 h-6 text-base-content/40" />
              </div>
              <p class="text-sm font-medium text-base-content/60">No claims in graph</p>
              <p class="text-xs text-base-content/40 mt-1">Import a document to get started</p>
            </div>
          <% else %>
            <div
              id="cy"
              phx-hook="CytoscapeGraph"
              data-graph={Jason.encode!(@graph_data)}
              data-connect-mode={to_string(!is_nil(@connect_from))}
              class={["w-full h-full", if(@connect_from, do: "cursor-crosshair", else: "")]}
            >
            </div>
            <%= if @connect_from do %>
              <div class="absolute top-3 left-1/2 -translate-x-1/2 z-10 flex items-center gap-3 rounded-xl bg-primary px-4 py-2.5 shadow-lg">
                <.icon name="hero-link" class="w-4 h-4 text-primary-content" />
                <span class="text-sm font-medium text-primary-content">Click a second node to connect</span>
                <button phx-click="cancel_connect" class="ml-1 rounded-lg bg-primary-content/20 p-1 hover:bg-primary-content/30 transition-colors">
                  <.icon name="hero-x-mark" class="w-3.5 h-3.5 text-primary-content" />
                </button>
              </div>
            <% end %>
            <div class="absolute bottom-3 right-3 flex gap-1.5">
              <div class="rounded-lg bg-base-100/90 border border-base-200 px-2.5 py-1 text-xs text-base-content/50 backdrop-blur-sm">
                {@graph_data.nodes |> length()} nodes · {@graph_data.edges |> length()} edges
              </div>
            </div>
          <% end %>
        </div>

        <%!-- Right sidebar: node detail --%>
        <%= if @selected_node do %>
          <div class="w-72 shrink-0 border-l border-base-200 bg-base-100 flex flex-col overflow-y-auto">
            <div class="flex items-center justify-between px-4 py-3 border-b border-base-200 shrink-0">
              <h3 class="text-sm font-semibold text-base-content">Claim detail</h3>
              <button
                phx-click="deselect"
                class="flex h-7 w-7 items-center justify-center rounded-lg text-base-content/40 hover:text-base-content hover:bg-base-200 transition-colors"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            </div>

            <div class="px-4 py-4 space-y-4 text-sm">
              <%!-- Type + layer badges --%>
              <div class="flex flex-wrap gap-1.5">
                <%= if @selected_node.type do %>
                  <span class="inline-flex items-center rounded-full bg-primary/10 px-2.5 py-0.5 text-xs font-medium text-primary capitalize">
                    {@selected_node.type}
                  </span>
                <% end %>
                <%= if @selected_node.corpus_layer do %>
                  <span class="inline-flex items-center rounded-full bg-base-200 px-2.5 py-0.5 text-xs text-base-content/60">
                    {corpus_layer_label(@selected_node.corpus_layer)}
                  </span>
                <% end %>
                <%= if @selected_node.human_validated do %>
                  <span class="inline-flex items-center rounded-full bg-success/10 px-2.5 py-0.5 text-xs font-medium text-success">
                    validated
                  </span>
                <% end %>
                <%= if @selected_node.contested do %>
                  <span class="inline-flex items-center rounded-full bg-warning/10 px-2.5 py-0.5 text-xs font-medium text-warning">
                    contested
                  </span>
                <% end %>
              </div>

              <%!-- Summary --%>
              <div>
                <p class="text-xs font-medium text-base-content/50 mb-1">Summary</p>
                <p class="text-sm font-medium text-base-content">{@selected_node.summary}</p>
              </div>

              <%!-- Full content --%>
              <div>
                <p class="text-xs font-medium text-base-content/50 mb-1">Claim</p>
                <p class="text-sm text-base-content/80 leading-relaxed">{@selected_node.content}</p>
              </div>

              <%!-- Confidence --%>
              <div>
                <p class="text-xs font-medium text-base-content/50 mb-1.5">Confidence</p>
                <div class="flex items-center gap-2">
                  <div class="flex-1 h-1.5 rounded-full bg-base-300 overflow-hidden">
                    <div
                      class="h-full rounded-full bg-primary transition-all"
                      style={"width: #{round((@selected_node.confidence || 1.0) * 100)}%"}
                    >
                    </div>
                  </div>
                  <span class="text-xs text-base-content/50 tabular-nums">
                    {Float.round(@selected_node.confidence || 1.0, 2)}
                  </span>
                </div>
              </div>

              <%!-- Tags --%>
              <%= if @selected_node.tags && @selected_node.tags != [] do %>
                <div>
                  <p class="text-xs font-medium text-base-content/50 mb-1.5">Tags</p>
                  <div class="flex flex-wrap gap-1">
                    <%= for tag <- @selected_node.tags do %>
                      <span class="rounded-md bg-base-200 px-2 py-0.5 text-xs text-base-content/60">
                        {tag}
                      </span>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%!-- Source document --%>
              <%= if @selected_node.source_document do %>
                <div class="rounded-lg border border-base-200 bg-base-200/40 p-3">
                  <p class="text-xs font-medium text-base-content/50 mb-1">Source document</p>
                  <p class="text-xs font-medium text-base-content">{@selected_node.source_document.title}</p>
                  <%= if @selected_node.source_document.document_date do %>
                    <p class="text-xs text-base-content/45 mt-0.5">
                      {Calendar.strftime(@selected_node.source_document.document_date, "%b %-d, %Y")}
                    </p>
                  <% end %>
                </div>
              <% end %>

              <%!-- Asserted at --%>
              <%= if @selected_node.asserted_at do %>
                <div>
                  <p class="text-xs font-medium text-base-content/50 mb-1">Asserted</p>
                  <p class="text-xs text-base-content/60">
                    {Calendar.strftime(@selected_node.asserted_at, "%b %-d, %Y")}
                  </p>
                </div>
              <% end %>

              <%!-- Edges --%>
              <%= if @selected_node[:edges] && @selected_node.edges != [] do %>
                <div>
                  <p class="text-xs font-medium text-base-content/50 mb-2">Edges</p>
                  <div class="space-y-1.5">
                    <%= for edge <- @selected_node.edges do %>
                      <div class="rounded-lg border border-base-200 bg-base-200/30 px-3 py-2">
                        <div class="flex items-start justify-between gap-2">
                          <div class="min-w-0">
                            <div class="flex items-center gap-1 text-xs text-base-content/50 mb-0.5">
                              <%= if edge.direction == :out do %>
                                <span class="text-base-content/40">→</span>
                              <% else %>
                                <span class="text-base-content/40">←</span>
                              <% end %>
                              <span class="font-medium text-primary capitalize">{edge.type}</span>
                            </div>
                            <p class="text-xs text-base-content/70 truncate">{edge.other_label}</p>
                          </div>
                          <div class="shrink-0">
                            <%= if @confirm_delete_edge == edge.id do %>
                              <div class="flex items-center gap-1">
                                <button
                                  phx-click="delete_edge"
                                  phx-value-id={edge.id}
                                  class="rounded px-2 py-0.5 text-xs font-medium bg-error text-error-content hover:brightness-110 transition-all"
                                >
                                  Hide
                                </button>
                                <button
                                  phx-click="cancel_delete_edge"
                                  class="rounded px-2 py-0.5 text-xs text-base-content/50 hover:bg-base-200 transition-colors"
                                >
                                  Cancel
                                </button>
                              </div>
                            <% else %>
                              <button
                                phx-click="confirm_delete_edge"
                                phx-value-id={edge.id}
                                class="rounded p-1 text-base-content/25 hover:text-error hover:bg-error/10 transition-colors"
                                title="Delete edge"
                              >
                                <.icon name="hero-trash" class="w-3.5 h-3.5" />
                              </button>
                            <% end %>
                          </div>
                        </div>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>

              <%!-- Connect action --%>
              <div class="pt-2 border-t border-base-200">
                <button
                  phx-click="start_connect"
                  class="w-full inline-flex items-center justify-center gap-2 rounded-lg border border-base-300 px-3 py-2 text-xs font-medium text-base-content/60 hover:bg-base-200 hover:text-base-content transition-colors"
                >
                  <.icon name="hero-link" class="w-3.5 h-3.5" /> Connect to another node
                </button>
              </div>
            </div>
          </div>
        <% end %>

      </div>
    </Layouts.app>
    """
  end
end
