defmodule XwaWeb.GraphLive do
  use XwaWeb, :live_view

  alias Xwa.Graph.{Nodes, Edges, FocusScorer}
  alias Xwa.{Documents, Graphs}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :load_graph, 50)

    socket =
      socket
      |> assign(:loading, true)
      |> assign(:selected_node, nil)
      |> assign(:neighborhood, nil)
      |> assign(:filter_layer, "all")
      |> assign(:filter_type, "all")
      |> assign(:filter_min_degree, 2)
      |> assign(:search, "")
      |> assign(:nodes, [])
      |> assign(:all_edges, [])
      |> assign(:graph_data, build_graph_data([], []))
      |> assign(:connect_from, nil)
      |> assign(:new_edge_modal, nil)
      |> assign(:confirm_delete_edge, nil)
      |> assign(:focus_mode, false)
      |> assign(:focus_prompt, "")
      |> assign(:focus_loading, false)
      |> assign(:focus_neighborhoods, nil)
      |> assign(:focus_history, [])
      |> assign(:selection_history, [])
      |> assign(:explore_tab, :focus)
      |> assign(:explore_slider, 50)
      |> assign(:explore_loading, false)
      |> assign(:doc_modal, nil)

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

    neighborhood =
      with true <- not is_nil(socket.assigns.current_scope.graph_id),
           graph_id = socket.assigns.current_scope.graph_id,
           user_id = socket.assigns.current_scope.user.id,
           graph_ids = Graphs.resolve_graph_ids(graph_id),
           {:ok, %{nodes: nbr_nodes}} <- Nodes.neighborhood(node_id, graph_ids, user_id: user_id) do
        %{center_id: node_id, ids: Enum.map(nbr_nodes, & &1.id)}
      else
        _ -> nil
      end

    # Double-tap: pop selection history first, then focus history
    already_selected = match?(%{id: ^node_id}, socket.assigns.selected_node)
    cond do
      already_selected ->
        case socket.assigns.selection_history do
          [%{selected_node: prev_node, neighborhood: prev_neighborhood} | rest] ->
            socket = assign(socket,
              selected_node: prev_node,
              neighborhood: prev_neighborhood,
              selection_history: rest,
              confirm_delete_edge: nil
            )
            {:noreply, push_canvas_events(socket)}
          [] ->
            # Selection history exhausted — pop focus history or clear
            if socket.assigns.focus_history != [] do
              handle_event("focus_back", %{}, socket)
            else
              socket = assign(socket, selected_node: nil, neighborhood: nil, selection_history: [])
              {:noreply, push_canvas_events(socket)}
            end
        end

      true ->
        # Push current selection onto history before switching to new node
        selection_history =
          if socket.assigns.selected_node do
            [%{selected_node: socket.assigns.selected_node, neighborhood: socket.assigns.neighborhood}
             | socket.assigns.selection_history]
          else
            socket.assigns.selection_history
          end

        socket =
          if socket.assigns.focus_mode and socket.assigns.focus_neighborhoods not in [nil, []] do
            history_entry = %{prompt: socket.assigns.focus_prompt, neighborhoods: socket.assigns.focus_neighborhoods}
            assign(socket,
              focus_neighborhoods: nil,
              focus_loading: false,
              focus_history: [history_entry | socket.assigns.focus_history]
            )
          else
            socket
          end

        socket = assign(socket,
          selected_node: selected,
          neighborhood: neighborhood,
          selection_history: selection_history,
          confirm_delete_edge: nil
        )
        {:noreply, push_canvas_events(socket)}
    end
  end

  def handle_event("unwind_to", %{"id" => target_id}, socket) do
    # Pop selection_history until we find the entry where selected_node.id == target_id
    history = socket.assigns.selection_history
    case Enum.split_while(history, fn %{selected_node: n} -> n && n.id != target_id end) do
      {_discarded, [%{selected_node: node, neighborhood: neighborhood} | rest]} ->
        socket = assign(socket,
          selected_node: node,
          neighborhood: neighborhood,
          selection_history: rest,
          confirm_delete_edge: nil
        )
        {:noreply, push_canvas_events(socket)}
      _ ->
        # Target not found in history — ignore
        {:noreply, socket}
    end
  end

  def handle_event("deselect", _params, socket) do
    socket = assign(socket, selected_node: nil, neighborhood: nil, connect_from: nil, new_edge_modal: nil, confirm_delete_edge: nil, selection_history: [])
    {:noreply, push_canvas_events(socket)}
  end

  def handle_event("enter_focus_mode", _params, socket) do
    {:noreply, assign(socket, focus_mode: true, focus_prompt: "", focus_loading: false, focus_neighborhoods: nil)}
  end

  def handle_event("exit_focus_mode", _params, socket) do
    socket = assign(socket, focus_mode: false, focus_loading: false, focus_neighborhoods: nil, selected_node: nil, neighborhood: nil, focus_history: [], selection_history: [], explore_tab: :focus, explore_slider: 50, explore_loading: false)
    {:noreply, push_canvas_events(socket)}
  end

  def handle_event("focus_back", _params, socket) do
    case socket.assigns.focus_history do
      [%{prompt: prompt, neighborhoods: neighborhoods} | rest] ->
        socket = assign(socket,
          focus_mode: true,
          focus_prompt: prompt,
          focus_neighborhoods: neighborhoods,
          focus_loading: false,
          focus_history: rest,
          selected_node: nil,
          neighborhood: nil
        )
        {:noreply, push_canvas_events(socket)}
      [] ->
        socket = assign(socket, focus_mode: false, focus_neighborhoods: nil)
        {:noreply, push_canvas_events(socket)}
    end
  end

  def handle_event("focus_submit", %{"prompt" => prompt}, socket) when prompt != "" do
    send(self(), {:run_focus, String.trim(prompt)})
    {:noreply, assign(socket, focus_loading: true, focus_prompt: prompt, focus_neighborhoods: nil)}
  end

  def handle_event("focus_submit", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("set_explore_tab", %{"tab" => tab}, socket) do
    tab = if tab == "explore", do: :explore, else: :focus
    {:noreply, assign(socket, explore_tab: tab)}
  end

  def handle_event("explore_submit", %{"slider" => slider_str}, socket) do
    slider = String.to_integer(slider_str)
    send(self(), {:run_explore, slider})
    {:noreply, assign(socket, explore_loading: true, explore_slider: slider, focus_neighborhoods: nil)}
  end

  def handle_event("open_doc_modal", %{"id" => doc_id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    case Documents.get_decrypted_content(doc_id, user_id) do
      {:ok, %{extracted_text: text}} ->
        doc = Documents.get_document(doc_id)
        modal = %{title: doc && doc.title, text: text, date: doc && doc.document_date}
        {:noreply, assign(socket, doc_modal: modal)}
      _ ->
        {:noreply, put_flash(socket, :error, "Could not load document content")}
    end
  end

  def handle_event("close_doc_modal", _params, socket) do
    {:noreply, assign(socket, doc_modal: nil)}
  end

  @impl true
  def handle_info(:load_graph, socket) do
    user_id = socket.assigns.current_scope.user.id
    graph_id = socket.assigns.current_scope.graph_id

    {nodes, edges} =
      if graph_id do
        graph_ids = Graphs.resolve_graph_ids(graph_id)
        require Logger
        Logger.info("[GraphLive] loading graph_id=#{graph_id} graph_ids=#{inspect(graph_ids)}")

        n_result = Nodes.list(graph_ids, user_id: user_id)
        e_result = all_edges(graph_ids, user_id)
        Logger.info("[GraphLive] nodes=#{inspect(n_result |> elem(0))} count=#{(match?({:ok, _}, n_result) && length(elem(n_result, 1))) || :error}")
        Logger.info("[GraphLive] edges result=#{inspect(e_result |> elem(0))} count=#{(match?({:ok, _}, e_result) && length(elem(e_result, 1))) || :error}")

        n = case n_result do
          {:ok, list} -> list
          err -> Logger.error("[GraphLive] nodes error: #{inspect(err)}"); []
        end
        e = case e_result do
          {:ok, list} -> list
          err -> Logger.error("[GraphLive] edges error: #{inspect(err)}"); []
        end
        {n, e}
      else
        {[], []}
      end

    min_degree = auto_threshold(nodes, edges)

    socket =
      socket
      |> assign(:loading, false)
      |> assign(:nodes, nodes)
      |> assign(:all_edges, edges)
      |> apply_filters(socket.assigns.filter_layer, socket.assigns.filter_type, socket.assigns.search, min_degree, true)

    {:noreply, socket}
  end

  def handle_info({:run_focus, prompt}, socket) do
    graph_id = socket.assigns.current_scope.graph_id
    user_id = socket.assigns.current_scope.user.id
    graph_ids = Graphs.resolve_graph_ids(graph_id)
    nodes = socket.assigns.nodes

    node_summaries = Enum.map(nodes, fn n ->
      %{id: n.id, summary: n.summary || n.content || ""}
    end)

    neighborhoods =
      with {:ok, top_ids} when top_ids != [] <- FocusScorer.score(prompt, node_summaries),
           top_ids = Enum.take(top_ids, 3) do
        top_ids
        |> Task.async_stream(
          fn node_id ->
            case Nodes.neighborhood(node_id, graph_ids, user_id: user_id) do
              {:ok, %{nodes: nb_nodes}} ->
                %{center_id: node_id, ids: Enum.map(nb_nodes, & &1.id)}
              _ ->
                nil
            end
          end,
          timeout: 15_000
        )
        |> Enum.flat_map(fn
          {:ok, result} when not is_nil(result) -> [result]
          _ -> []
        end)
      else
        _ -> []
      end

    socket = assign(socket, focus_loading: false, focus_neighborhoods: neighborhoods)
    {:noreply, push_canvas_events(socket)}
  end

  def handle_info({:run_explore, slider}, socket) do
    nodes = socket.assigns.nodes
    all_edges = socket.assigns.all_edges
    graph_id = socket.assigns.current_scope.graph_id
    user_id = socket.assigns.current_scope.user.id
    graph_ids = Graphs.resolve_graph_ids(graph_id)

    edge_counts =
      Enum.reduce(all_edges, %{}, fn e, acc ->
        acc
        |> Map.update(e.from_node_id, 1, &(&1 + 1))
        |> Map.update(e.to_node_id, 1, &(&1 + 1))
      end)

    top_ids =
      if slider == -1 do
        nodes
        |> Enum.filter(&(Map.get(edge_counts, &1.id, 0) == 0))
        |> Enum.shuffle()
        |> Enum.take(3)
        |> Enum.map(& &1.id)
      else
        sorted = Enum.sort_by(nodes, &Map.get(edge_counts, &1.id, 0))
        total = length(sorted)
        target_idx = round(slider / 100 * (total - 1))
        target_count = Map.get(edge_counts, Enum.at(sorted, target_idx).id, 0)
        sorted
        |> Enum.sort_by(&abs(Map.get(edge_counts, &1.id, 0) - target_count))
        |> Enum.take(9)
        |> Enum.shuffle()
        |> Enum.take(3)
        |> Enum.map(& &1.id)
      end

    neighborhoods =
      top_ids
      |> Task.async_stream(
        fn node_id ->
          case Nodes.neighborhood(node_id, graph_ids, user_id: user_id) do
            {:ok, %{nodes: nb_nodes}} ->
              %{center_id: node_id, ids: Enum.map(nb_nodes, & &1.id)}
            _ ->
              %{center_id: node_id, ids: []}
          end
        end,
        timeout: 15_000
      )
      |> Enum.flat_map(fn
        {:ok, result} -> [result]
        _ -> []
      end)

    socket = assign(socket, explore_loading: false, focus_neighborhoods: neighborhoods, focus_mode: true)
    {:noreply, push_canvas_events(socket)}
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
    graph_id = socket.assigns.current_scope.graph_id
    modal = socket.assigns.new_edge_modal

    attrs = %{
      from_node_id: modal.from_id,
      to_node_id: modal.to_id,
      type: String.trim(params["type"] || "relates"),
      certainty: params["certainty"] || "solid",
      confidence: 1.0,
      ai_inferred: false,
      human_validated: true,
      created_by: user_id,
      graph_id: graph_id
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

  def handle_event("filter_min_degree", %{"min_degree" => val}, socket) do
    min_degree = String.to_integer(val)
    socket = apply_filters(socket, socket.assigns.filter_layer, socket.assigns.filter_type, socket.assigns.search, min_degree, true)
    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp all_edges(graph_ids, user_id) do
    Edges.list(graph_ids, user_id)
  end

  defp apply_filters(socket, layer, type, search, min_degree \\ nil, full_reload \\ false) do
    min_degree = min_degree || socket.assigns.filter_min_degree
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

    graph_data = build_graph_data(filtered, filtered_edges, composite_id(socket))

    # Pass min_degree to the JS hook so it can hide low-degree nodes via CSS
    # display:none rather than removing them from Cytoscape's element set.
    # This keeps all nodes available for neighborhood display.
    event_data =
      graph_data
      |> Map.put(:min_degree, min_degree)
      |> then(&if full_reload, do: Map.put(&1, :full_reload, true), else: &1)

    socket
    |> assign(:filter_layer, layer)
    |> assign(:filter_type, type)
    |> assign(:filter_min_degree, min_degree)
    |> assign(:search, search)
    |> assign(:graph_data, graph_data)
    |> push_event("graph_loaded", event_data)
  end

  # Push canvas overlay events to the hook whenever neighborhood or focus changes.
  # Since #cy uses phx-update="ignore", LiveView never patches its data-* attributes,
  # so the hook can't rely on updated() for these — they must come via push_event.
  defp push_canvas_events(socket) do
    socket
    |> push_event("neighborhood_changed", socket.assigns.neighborhood || %{})
    |> push_event("focus_changed", %{neighborhoods: socket.assigns.focus_neighborhoods || []})
  end

  defp composite_id(socket) do
    graph = socket.assigns.current_scope.graph
    if graph && graph.is_composite, do: graph.id, else: nil
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

  defp build_graph_data(nodes, edges, composite_graph_id \\ nil) do
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
        cross_graph = not is_nil(composite_graph_id) and e.graph_id == composite_graph_id
        %{
          data: %{
            id: e.id,
            source: e.from_node_id,
            target: e.to_node_id,
            type: e.type || "relates",
            certainty: e.certainty || "dashed",
            confidence: e.confidence || 0.5,
            cross_graph: cross_graph
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

  # Compute the minimum degree threshold that yields 250–350 visible nodes.
  # Tries thresholds 1..20 and picks the lowest that keeps node count <= 350.
  # If the full graph has <= 250 nodes, returns 0 (show orphans too).
  # If even threshold=20 gives >350, returns 20 (keep pruning).
  defp auto_threshold(nodes, edges) do
    total = length(nodes)
    if total <= 250 do
      0
    else
      edge_counts =
        Enum.reduce(edges, %{}, fn e, acc ->
          acc
          |> Map.update(e.from_node_id, 1, &(&1 + 1))
          |> Map.update(e.to_node_id, 1, &(&1 + 1))
        end)

      Enum.find(1..20, 20, fn threshold ->
        count = Enum.count(nodes, fn n -> Map.get(edge_counts, n.id, 0) >= threshold end)
        count <= 350
      end)
    end
  end

  defp corpus_layer_label("self_description"), do: "Self-description"
  defp corpus_layer_label("internal_record"), do: "Internal record"
  defp corpus_layer_label("external_context"), do: "External context"
  defp corpus_layer_label(other), do: other || "Unknown"

  defp layer_dot_class("self_description"), do: "bg-primary"
  defp layer_dot_class("internal_record"), do: "bg-secondary"
  defp layer_dot_class("external_context"), do: "bg-accent"
  defp layer_dot_class(_), do: "bg-base-400"

  @url_regex ~r/\Ahttps?:\/\/\S+\z/

  defp url?(nil), do: false
  defp url?(str), do: String.match?(String.trim(str), @url_regex)

  # Returns the first URL found in a string, or nil
  defp extract_url(nil), do: nil
  defp extract_url(str) do
    case Regex.run(~r/https?:\/\/\S+/, str) do
      [url | _] -> url
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :node_types, node_types(assigns.nodes))

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex -mx-4 -my-8 overflow-hidden" style="height: calc(100vh - 4rem)">

        <%!-- Left sidebar: focus/explore + filters --%>
        <div class="w-56 shrink-0 border-r border-base-200 bg-base-100 flex flex-col overflow-y-auto">

          <%!-- Focus / Explore panel --%>
          <%= if @focus_mode do %>
            <div class="border-b border-base-200">
              <%!-- Tab bar --%>
              <%= if @focus_neighborhoods in [nil, []] do %>
                <div class="flex border-b border-base-200">
                  <button phx-click="set_explore_tab" phx-value-tab="focus"
                    class={["flex-1 py-2 text-xs font-medium transition-colors",
                      if(@explore_tab == :focus, do: "text-primary bg-primary/5", else: "text-base-content/50 hover:text-base-content")]}>
                    <.icon name="hero-viewfinder-circle" class="w-3 h-3 inline mr-1" />Focus
                  </button>
                  <button phx-click="set_explore_tab" phx-value-tab="explore"
                    class={["flex-1 py-2 text-xs font-medium transition-colors",
                      if(@explore_tab == :explore, do: "text-primary bg-primary/5", else: "text-base-content/50 hover:text-base-content")]}>
                    <.icon name="hero-map" class="w-3 h-3 inline mr-1" />Explore
                  </button>
                  <button phx-click="exit_focus_mode" class="px-3 text-base-content/30 hover:text-base-content transition-colors">
                    <.icon name="hero-x-mark" class="w-4 h-4" />
                  </button>
                </div>
              <% end %>
              <div class="p-3">
                <%= if @focus_neighborhoods not in [nil, []] do %>
                  <%!-- Active: breadcrumb --%>
                  <div class="flex items-center gap-2">
                    <.icon name="hero-viewfinder-circle" class="w-3.5 h-3.5 text-primary shrink-0" />
                    <p class="flex-1 text-xs text-base-content/70 truncate">{@focus_prompt}</p>
                    <%= if @focus_history != [] do %>
                      <button phx-click="focus_back"
                        class="shrink-0 flex items-center gap-1 text-xs text-base-content/50 hover:text-base-content transition-colors"
                        title="Back to previous focus">
                        <.icon name="hero-arrow-left" class="w-3 h-3" /> Back
                      </button>
                    <% end %>
                    <button phx-click="exit_focus_mode" class="shrink-0 text-base-content/30 hover:text-base-content transition-colors">
                      <.icon name="hero-x-mark" class="w-4 h-4" />
                    </button>
                  </div>
                <% else %>
                  <%= if @explore_tab == :focus do %>
                    <%!-- Focus tab: intent textarea --%>
                    <form phx-submit="focus_submit" class="flex flex-col gap-2">
                      <textarea name="prompt" rows="2" placeholder="What are you working on?" autofocus
                        class="w-full rounded-lg border border-base-300 bg-base-200/50 px-2.5 py-2 text-xs resize-none focus:border-primary focus:outline-none focus:ring-1 focus:ring-primary"
                        disabled={@focus_loading}></textarea>
                      <button type="submit" disabled={@focus_loading}
                        class="w-full rounded-lg bg-primary px-3 py-1.5 text-xs font-medium text-primary-content hover:brightness-110 disabled:opacity-50 transition-all">
                        <%= if @focus_loading, do: "Finding…", else: "Find relevant areas" %>
                      </button>
                    </form>
                  <% else %>
                    <%!-- Explore tab: slider + There Be Dragons --%>
                    <form phx-submit="explore_submit" class="flex flex-col gap-3">
                      <div class="flex items-center gap-2">
                        <button type="button" phx-click="explore_submit" phx-value-slider="-1"
                          class="shrink-0 text-xs px-2 py-1 rounded border border-warning/50 text-warning hover:bg-warning/10 transition-colors"
                          title="Show only unconnected nodes">
                          ⚠
                        </button>
                        <input type="range" name="slider" min="0" max="100" value={@explore_slider}
                          class="flex-1 accent-primary" />
                      </div>
                      <div class="flex justify-between text-xs text-base-content/40">
                        <span>Bushwhacking</span>
                        <span>Worn Paths</span>
                      </div>
                      <button type="submit" disabled={@explore_loading}
                        class="w-full rounded-lg bg-primary px-3 py-1.5 text-xs font-medium text-primary-content hover:brightness-110 disabled:opacity-50 transition-all">
                        <%= if @explore_loading, do: "Exploring…", else: "Explore" %>
                      </button>
                    </form>
                  <% end %>
                <% end %>
              </div>
            </div>
          <% else %>
            <%!-- Focus entry button --%>
            <div class="px-4 py-3 border-b border-base-200">
              <button
                phx-click="enter_focus_mode"
                class="w-full flex items-center gap-2 rounded-lg border border-base-300 px-2.5 py-2 text-xs text-base-content/60 hover:bg-base-200 hover:text-base-content transition-colors"
              >
                <.icon name="hero-viewfinder-circle" class="w-3.5 h-3.5" />
                Focus / Explore
              </button>
            </div>
          <% end %>

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

            <%!-- Min connections slider --%>
            <div class="mb-4">
              <div class="flex items-center justify-between mb-1.5">
                <p class="text-xs font-medium text-base-content/50">Min connections</p>
                <span id="cy-degree-label" class="text-xs font-semibold text-primary"><%= @filter_min_degree %></span>
              </div>
              <input
                id="cy-degree-slider"
                type="range"
                min="1" max="10"
                value={@filter_min_degree}
                phx-hook="DegreeSlider"
                phx-update="ignore"
                class="w-full accent-primary"
              />
              <div class="flex justify-between text-xs text-base-content/30 mt-0.5">
                <span>All</span>
                <span>10+</span>
              </div>
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

        <%!-- Document viewer modal --%>
        <%= if @doc_modal do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 backdrop-blur-sm">
            <div class="bg-base-100 rounded-2xl shadow-2xl flex flex-col w-full max-w-2xl mx-4" style="max-height: 80vh">
              <div class="flex items-start justify-between px-5 py-4 border-b border-base-200 shrink-0">
                <div class="min-w-0 pr-4">
                  <h3 class="text-sm font-semibold text-base-content break-words">{@doc_modal.title}</h3>
                  <%= if @doc_modal.date do %>
                    <p class="text-xs text-base-content/45 mt-0.5">{Calendar.strftime(@doc_modal.date, "%b %-d, %Y")}</p>
                  <% end %>
                </div>
                <button phx-click="close_doc_modal"
                  class="shrink-0 flex h-7 w-7 items-center justify-center rounded-lg text-base-content/40 hover:text-base-content hover:bg-base-200 transition-colors">
                  <.icon name="hero-x-mark" class="w-4 h-4" />
                </button>
              </div>
              <div class="flex-1 overflow-y-auto px-5 py-4">
                <%= if @doc_modal.text do %>
                  <pre class="text-xs text-base-content/80 font-sans whitespace-pre-wrap break-words leading-relaxed">{@doc_modal.text}</pre>
                <% else %>
                  <p class="text-sm text-base-content/50 text-center py-8">No extracted text available for this document.</p>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>

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
          <%!-- Loading spinner: always in DOM, JS hook hides it after layout completes --%>
          <div
            id="cy-loading"
            phx-update="ignore"
            class="absolute inset-0 flex flex-col items-center justify-center text-center z-10 bg-base-100 transition-opacity duration-300"
          >
            <svg class="animate-spin h-8 w-8 text-primary mb-3" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
              <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
            </svg>
            <p id="cy-loading-msg" class="text-sm text-base-content/60">Loading graph…</p>
          </div>
          <%!-- Empty state: only shown after loading completes --%>
          <%= if !@loading && @graph_data.nodes == [] do %>
            <div class="absolute inset-0 flex flex-col items-center justify-center text-center">
              <div class="flex h-12 w-12 items-center justify-center rounded-xl bg-base-200 mb-4">
                <.icon name="hero-circle-stack" class="w-6 h-6 text-base-content/40" />
              </div>
              <p class="text-sm font-medium text-base-content/60">No claims in graph</p>
              <p class="text-xs text-base-content/40 mt-1">Import a document to get started</p>
            </div>
          <% end %>
          <%!-- Canvas label panel: explored trail + hover label, upper-left corner --%>
          <div
            id="cy-label-panel"
            phx-update="ignore"
            class="absolute top-3 left-3 z-20 flex flex-col gap-1 max-w-xs"
          >
            <%!-- Explored node labels — clickable back buttons --%>
            <div id="cy-explored-labels" class="flex flex-col gap-1"></div>
            <%!-- Current hover label sits below the trail --%>
            <span id="cy-hover-text" class="pointer-events-none text-sm font-medium text-base-content bg-base-100/90 backdrop-blur-sm px-3 py-1 rounded-lg shadow border border-base-300 truncate" style="display:none;"></span>
          </div>
          <%!-- Canvas: always in DOM so LiveView patches rather than replaces it --%>
          <div
            id="cy"
            phx-hook="CytoscapeGraph"
            phx-update="ignore"
            data-graph={Jason.encode!(@graph_data)}
            data-neighborhood={Jason.encode!(@neighborhood)}
            data-focus={Jason.encode!(@focus_neighborhoods)}
            class={[if(@connect_from, do: "cursor-crosshair", else: "")]}
            style="position:absolute;top:0;right:0;bottom:0;left:0;"
          >
          </div>
          <%!-- Connect banner --%>
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
        </div>

        <%!-- Right sidebar: node detail (always rendered so layout never shifts) --%>
        <div class="w-72 shrink-0 border-l border-base-200 bg-base-100 flex flex-col overflow-y-auto">
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-200 shrink-0">
            <h3 class="text-sm font-semibold text-base-content">Claim detail</h3>
            <%= if @selected_node do %>
              <button
                phx-click="deselect"
                class="flex h-7 w-7 items-center justify-center rounded-lg text-base-content/40 hover:text-base-content hover:bg-base-200 transition-colors"
              >
                <.icon name="hero-x-mark" class="w-4 h-4" />
              </button>
            <% end %>
          </div>

          <%= if @selected_node do %>
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
                <%= if url?(@selected_node.summary) do %>
                  <a href={String.trim(@selected_node.summary)} target="_blank" rel="noopener noreferrer"
                    class="text-sm font-medium text-primary hover:underline break-all">
                    {@selected_node.summary}
                  </a>
                <% else %>
                  <p class="text-sm font-medium text-base-content break-words">{@selected_node.summary}</p>
                <% end %>
              </div>

              <%!-- Full content --%>
              <div>
                <p class="text-xs font-medium text-base-content/50 mb-1">Claim</p>
                <%= if url?(@selected_node.content) do %>
                  <a href={String.trim(@selected_node.content)} target="_blank" rel="noopener noreferrer"
                    class="text-sm text-primary hover:underline break-all">
                    {@selected_node.content}
                  </a>
                <% else %>
                  <p class="text-sm text-base-content/80 leading-relaxed break-words">
                    {@selected_node.content}
                    <%= if extract_url(@selected_node.content) do %>
                      <a href={extract_url(@selected_node.content)} target="_blank" rel="noopener noreferrer"
                        class="inline-flex items-center gap-0.5 text-primary hover:underline ml-1">
                        <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
                      </a>
                    <% end %>
                  </p>
                <% end %>
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
                  <button phx-click="open_doc_modal" phx-value-id={@selected_node.source_document.id}
                    class="flex items-start gap-1 group text-left w-full">
                    <p class="text-xs font-medium text-base-content group-hover:text-primary break-words transition-colors">{@selected_node.source_document.title}</p>
                    <.icon name="hero-document-text" class="w-3 h-3 text-base-content/30 group-hover:text-primary shrink-0 mt-0.5 transition-colors" />
                  </button>
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
                            <p class="text-xs text-base-content/70 break-words">{edge.other_label}</p>
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
          <% else %>
            <%!-- Empty state --%>
            <div class="flex flex-col items-center justify-center flex-1 px-4 text-center">
              <div class="flex h-10 w-10 items-center justify-center rounded-xl bg-base-200 mb-3">
                <.icon name="hero-cursor-arrow-rays" class="w-5 h-5 text-base-content/30" />
              </div>
              <p class="text-xs text-base-content/40">Click a node to see claim details</p>
            </div>
          <% end %>
        </div>

      </div>
    </Layouts.app>
    """
  end
end
