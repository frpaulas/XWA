defmodule Mix.Tasks.BackfillEdges do
  @moduledoc """
  Runs edge extraction for all Claim nodes that have zero edges.

  Useful after the cosine-similarity neighbourhood fix: nodes ingested
  when edge extraction produced poor results (random 20 candidates) can
  be given a second pass with the improved ranking.

  ## Usage

      # Backfill a specific graph
      mix backfill_edges --graph-id <uuid>

      # Backfill all graphs
      mix backfill_edges

  Each isolated node fetches a cosine-ranked neighbourhood and calls
  Claude's EdgeExtractor. Requires ANTHROPIC_API_KEY and VOYAGE_API_KEY.
  Progress is printed after every node.
  """

  use Mix.Task
  require Logger

  alias Xwa.Graph.{Node, Nodes, Edges, VectorMath}
  alias Xwa.Ingestion.{EdgeExtractor, ExtractionRuns}

  @shortdoc "Backfill edge extraction for isolated (zero-edge) nodes"

  @neighbourhood_size 20

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} = OptionParser.parse!(args, strict: [graph_id: :string])
    graph_id = Keyword.get(opts, :graph_id)

    graph_ids = resolve_graph_ids(graph_id)

    Enum.each(graph_ids, &backfill_graph/1)
  end

  defp backfill_graph(graph_id) do
    Mix.shell().info("\nGraph #{graph_id}")
    Mix.shell().info("Fetching isolated nodes (zero edges)...")

    isolated = fetch_isolated_nodes(graph_id)
    total = length(isolated)

    if total == 0 do
      Mix.shell().info("  No isolated nodes. Done.")
    else
      Mix.shell().info("  Found #{total} isolated nodes. Fetching embeddings...")

      {:ok, embedding_pairs} = Nodes.list_embeddings(graph_id)
      embedding_map = Map.new(embedding_pairs)

      Mix.shell().info("  #{map_size(embedding_map)} nodes have embeddings for neighbourhood ranking.")

      {edges_added, skipped} =
        isolated
        |> Enum.with_index(1)
        |> Enum.reduce({0, 0}, fn {node, idx}, {edge_acc, skip_acc} ->
          Mix.shell().info("  [#{idx}/#{total}] #{node.id} — #{node.summary || String.slice(node.content || "", 0, 60)}")

          neighbours = fetch_neighbourhood(node, embedding_map, graph_id)

          if neighbours == [] do
            Mix.shell().info("    → no neighbours found, skipping")
            {edge_acc, skip_acc + 1}
          else
            context = %{
              document_id: node.source_document_id,
              graph_id: graph_id,
              created_by: node.created_by
            }

            case EdgeExtractor.extract(node, neighbours, context) do
              {:ok, edges, usage} ->
                unless map_size(usage) == 0 do
                  ExtractionRuns.log(%{
                    run_type: "edge",
                    document_id: node.source_document_id,
                    graph_id: graph_id,
                    status: "ok",
                    edges_extracted: length(edges),
                    duration_ms: 0,
                    usage: usage
                  })
                end

                inserted = insert_edges(edges)
                Mix.shell().info("    → #{inserted} edges added")
                {edge_acc + inserted, skip_acc}

              {:error, reason} ->
                Mix.shell().error("    → extraction failed: #{inspect(reason)}")
                {edge_acc, skip_acc + 1}
            end
          end
        end)

      Mix.shell().info("""

      Done for graph #{graph_id}.
        Isolated nodes   : #{total}
        Edges added      : #{edges_added}
        Skipped/failed   : #{skipped}
      """)
    end
  end

  defp fetch_isolated_nodes(graph_id) do
    cypher = """
    MATCH (n:Claim {graph_id: $graph_id})
    WHERE NOT (n)-[:RELATES]-() AND NOT ()-[:RELATES]-(n)
      AND (n.node_type IS NULL OR n.node_type = 'claim')
      AND n.content IS NOT NULL AND n.content <> ''
    RETURN n
    """

    case Xwa.Graph.query(cypher, %{graph_id: graph_id}) do
      {:ok, rows} -> Enum.map(rows, fn %{"n" => bolt} -> Node.from_bolt(bolt) end)
      _ -> []
    end
  end

  defp fetch_neighbourhood(node, embedding_map, graph_id) do
    node_emb = Map.get(embedding_map, node.id) || node.embedding

    if node_emb do
      norm_new = VectorMath.normalize(node_emb)

      top_ids =
        embedding_map
        |> Enum.reject(fn {id, _} -> id == node.id end)
        |> Enum.map(fn {id, emb} ->
          score = VectorMath.dot_product(norm_new, VectorMath.normalize(emb))
          {id, score}
        end)
        |> Enum.sort_by(fn {_, s} -> s end, :desc)
        |> Enum.take(@neighbourhood_size)
        |> Enum.map(fn {id, _} -> id end)
        |> MapSet.new()

      case Nodes.list(graph_id) do
        {:ok, nodes} ->
          nodes
          |> Enum.reject(&(&1.id == node.id))
          |> Enum.filter(&MapSet.member?(top_ids, &1.id))
        _ -> []
      end
    else
      # No embedding — fall back to first N nodes
      case Nodes.list(graph_id) do
        {:ok, nodes} ->
          nodes |> Enum.reject(&(&1.id == node.id)) |> Enum.take(@neighbourhood_size)
        _ -> []
      end
    end
  end

  defp insert_edges(edges) do
    Enum.reduce(edges, 0, fn edge, count ->
      case Edges.create(edge) do
        {:ok, _} -> count + 1
        {:error, reason} ->
          Mix.shell().error("    Failed to insert edge: #{inspect(reason)}")
          count
      end
    end)
  end

  defp resolve_graph_ids(nil) do
    Xwa.Repo.all(Xwa.Graphs.Graph) |> Enum.map(& &1.id)
  end

  defp resolve_graph_ids(graph_id), do: [graph_id]
end
