defmodule Mix.Tasks.RerunEdges do
  @moduledoc """
  Re-runs AI edge extraction for every node in a graph.

  Useful when nodes were ingested concurrently (and so saw an empty or
  near-empty graph at insert time) and therefore have few or no edges.

  For each node the task samples up to `--neighbourhood` nodes from
  *different* source documents in the same corpus layer, then calls
  EdgeExtractor and inserts the returned edges.  Already-connected node
  pairs are skipped to avoid redundant API calls.

  Usage:

    mix rerun_edges --graph-id UUID --user-id UUID [options]

  Options:
    --graph-id       UUID of the graph to process (required)
    --user-id        UUID of the user who owns the re-extraction (required)
    --concurrency    Number of concurrent Claude API calls (default: 3)
    --neighbourhood  Max neighbours to pass per node (default: 20)
    --skip-connected Skip nodes that already have at least one edge (default: true)
    --dry-run        Print counts without making API calls
  """

  use Mix.Task

  require Logger

  alias Xwa.Graph.{Nodes, Edges}
  alias Xwa.Ingestion.EdgeExtractor

  @shortdoc "Re-run AI edge extraction for all nodes in a graph"

  @neighbourhood_size 20
  @default_concurrency 3

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          graph_id: :string,
          user_id: :string,
          concurrency: :integer,
          neighbourhood: :integer,
          skip_connected: :boolean,
          dry_run: :boolean
        ]
      )

    graph_id = opts[:graph_id] || raise "--graph-id is required"
    user_id = opts[:user_id] || raise "--user-id is required"
    concurrency = opts[:concurrency] || @default_concurrency
    neighbourhood = opts[:neighbourhood] || @neighbourhood_size
    skip_connected = Keyword.get(opts, :skip_connected, true)
    dry_run = opts[:dry_run] || false

    Mix.shell().info("Fetching all nodes for graph #{graph_id}...")

    {:ok, all_nodes} = Nodes.list(graph_id, user_id: nil)

    Mix.shell().info("Found #{length(all_nodes)} nodes total.")

    if dry_run do
      Mix.shell().info("[dry-run] Would process up to #{length(all_nodes)} nodes.")
      Mix.shell().info("[dry-run] concurrency=#{concurrency}, neighbourhood=#{neighbourhood}, skip_connected=#{skip_connected}")
      :ok
    else
      nodes_to_process =
        if skip_connected do
          Mix.shell().info("Checking existing edges (skip_connected=true)...")
          filter_unconnected(all_nodes)
        else
          all_nodes
        end

      Mix.shell().info("Processing #{length(nodes_to_process)} nodes (skipping #{length(all_nodes) - length(nodes_to_process)} already connected).")

      context = %{graph_id: graph_id, created_by: user_id}

      # Group all nodes by source_document_id for cross-doc sampling
      by_doc = Enum.group_by(all_nodes, & &1.source_document_id)

      counters = :counters.new(3, [:atomics])
      # index 1 = processed, 2 = edges_inserted, 3 = errors

      total = length(nodes_to_process)

      nodes_to_process
      |> Task.async_stream(
        fn node ->
          process_node(node, by_doc, neighbourhood, context, counters)
        end,
        max_concurrency: concurrency,
        timeout: 120_000,
        on_timeout: :kill_task
      )
      |> Stream.with_index(1)
      |> Enum.each(fn {result, idx} ->
        if rem(idx, 10) == 0 or idx == total do
          processed = :counters.get(counters, 1)
          edges = :counters.get(counters, 2)
          errors = :counters.get(counters, 3)
          Mix.shell().info("[#{idx}/#{total}] processed=#{processed} edges_inserted=#{edges} errors=#{errors}")
        end

        case result do
          {:exit, reason} ->
            Mix.shell().error("  Task timed out or crashed: #{inspect(reason)}")
          _ ->
            :ok
        end
      end)

      processed = :counters.get(counters, 1)
      edges = :counters.get(counters, 2)
      errors = :counters.get(counters, 3)

      Mix.shell().info("")
      Mix.shell().info("Done: #{processed} nodes processed, #{edges} edges inserted, #{errors} errors.")
    end
  end

  # ---------------------------------------------------------------------------
  # Per-node processing
  # ---------------------------------------------------------------------------

  defp process_node(node, by_doc, neighbourhood, context, counters) do
    neighbours = sample_neighbours(node, by_doc, neighbourhood)

    node_context = Map.put(context, :document_id, node.source_document_id)

    case EdgeExtractor.extract(node, neighbours, node_context) do
      {:ok, edges, _usage} ->
        :counters.add(counters, 1, 1)
        inserted = insert_edges(edges)
        :counters.add(counters, 2, inserted)

      {:error, reason} ->
        :counters.add(counters, 1, 1)
        :counters.add(counters, 3, 1)
        Logger.warning("[RerunEdges] Edge extraction failed for node #{node.id}: #{inspect(reason)}")
    end
  end

  # ---------------------------------------------------------------------------
  # Neighbourhood sampling
  # ---------------------------------------------------------------------------

  # Sample up to `n` nodes from different source documents than `node`.
  # Prioritises variety: take one node per document, then top up if needed.
  defp sample_neighbours(node, by_doc, n) do
    other_docs =
      by_doc
      |> Enum.reject(fn {doc_id, _} -> doc_id == node.source_document_id end)
      |> Enum.map(fn {_doc_id, nodes} -> Enum.random(nodes) end)
      |> Enum.shuffle()

    Enum.take(other_docs, n)
  end

  # ---------------------------------------------------------------------------
  # Skip already-connected nodes
  # ---------------------------------------------------------------------------

  defp filter_unconnected(nodes) do
    Enum.filter(nodes, fn node ->
      case Edges.list_for_node(node.id, direction: :both) do
        {:ok, []} -> true
        {:ok, _} -> false
        {:error, _} -> true
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Edge insertion
  # ---------------------------------------------------------------------------

  defp insert_edges([]), do: 0

  defp insert_edges(edges) do
    Enum.reduce(edges, 0, fn edge, acc ->
      case Edges.create(edge) do
        {:ok, _} ->
          acc + 1

        {:error, reason} ->
          Logger.debug("[RerunEdges] Failed to insert edge: #{inspect(reason)}")
          acc
      end
    end)
  end
end
