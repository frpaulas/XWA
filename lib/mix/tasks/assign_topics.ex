defmodule Mix.Tasks.AssignTopics do
  @moduledoc """
  Assigns topic nodes to all existing claims that do not yet have a BELONGS_TO edge.

  Runs topic extraction (Claude) for each unassigned claim, deduplicates topics by
  cosine similarity (threshold 0.85), and creates BELONGS_TO edges.  Topic→topic
  edges are proposed only for newly created topics.

  ## Usage

      # Assign topics for all claims in all graphs
      mix assign_topics

      # Assign topics only for claims in a specific graph
      mix assign_topics --graph-id <uuid>

  This is safe to re-run — claims that already have a BELONGS_TO edge are skipped.
  """

  use Mix.Task
  require Logger

  alias Xwa.Graph.{Nodes, Topics}
  alias Xwa.Graphs
  alias Xwa.Ingestion.TopicExtractor

  @shortdoc "Backfill topic assignments for existing claims"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} = OptionParser.parse!(args, strict: [graph_id: :string])
    graph_id_filter = Keyword.get(opts, :graph_id)

    graphs =
      if graph_id_filter do
        case Graphs.get_graph(graph_id_filter) do
          nil -> Mix.raise("Graph #{graph_id_filter} not found")
          g   -> [g]
        end
      else
        Graphs.list_all_graphs()
      end

    Mix.shell().info("Processing #{length(graphs)} graph(s)...")

    Enum.each(graphs, fn graph ->
      org_id = graph.organization_id
      Mix.shell().info("\nGraph: #{graph.name} (#{graph.id}), org: #{org_id}")

      {:ok, nodes} = Nodes.list(graph.id, user_id: nil)
      claim_nodes = Enum.filter(nodes, &(&1.node_type == "claim"))

      # Find claims that already have a belongs_to edge
      {:ok, existing_edges} = Topics.list_belongs_to_edges(graph.id)
      already_assigned = MapSet.new(existing_edges, &(&1.from_node_id))

      unassigned = Enum.reject(claim_nodes, &MapSet.member?(already_assigned, &1.id))

      if unassigned == [] do
        Mix.shell().info("  All #{length(claim_nodes)} claims already assigned.")
      else
        Mix.shell().info("  #{length(unassigned)} of #{length(claim_nodes)} claims need topic assignment.")
        assign_topics_for_claims(unassigned, org_id, graph.id)
      end
    end)

    Mix.shell().info("\nDone.")
  end

  defp assign_topics_for_claims(nodes, org_id, graph_id) do
    total = length(nodes)

    nodes
    |> Enum.with_index(1)
    |> Enum.each(fn {node, idx} ->
      if rem(idx, 50) == 0 or idx == 1 or idx == total do
        Mix.shell().info("  [#{idx}/#{total}] Processing...")
      end

      claim_text = node.summary || node.content

      case TopicExtractor.extract_topic(claim_text) do
        {:ok, topic_label} ->
          case Topics.find_or_create(topic_label, org_id, created_by: node.created_by) do
            {:ok, topic_node, :created} ->
              Logger.info("[AssignTopics] Created topic '#{topic_label}'")
              Topics.assign_topic(node.id, topic_node.id, graph_id, node.created_by)

            {:ok, topic_node, :existing} ->
              Topics.assign_topic(node.id, topic_node.id, graph_id, node.created_by)

            {:error, reason} ->
              Logger.warning("[AssignTopics] find_or_create failed for '#{topic_label}': #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.warning("[AssignTopics] Topic extraction failed for node #{node.id}: #{inspect(reason)}")
      end
    end)
  end
end
