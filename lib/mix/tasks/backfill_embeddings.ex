defmodule Mix.Tasks.BackfillEmbeddings do
  @moduledoc """
  Generates Voyage AI embeddings for all Claim nodes that have a nil embedding.

  ## Usage

      # Backfill all graphs
      mix backfill_embeddings

      # Backfill a specific graph
      mix backfill_embeddings --graph-id <uuid>

  Processes nodes in batches of 128 (Voyage AI's per-request limit).
  Prints a cost summary when done.
  """

  use Mix.Task
  require Logger

  alias Xwa.Graph.Nodes
  alias Xwa.Ingestion.VoyageEmbedder

  @shortdoc "Backfill Voyage AI embeddings for nodes with nil embedding"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} = OptionParser.parse!(args, strict: [graph_id: :string])
    graph_id = Keyword.get(opts, :graph_id)

    graph_ids = resolve_graph_ids(graph_id)

    Mix.shell().info("Fetching nodes with missing embeddings...")

    {:ok, pairs} = Nodes.list_missing_embeddings(graph_ids)
    total = length(pairs)

    if total == 0 do
      Mix.shell().info("No nodes need embedding. Done.")
    else
      Mix.shell().info("Found #{total} nodes to embed.")

      {embedded, total_tokens, total_cost} =
        pairs
        |> Enum.chunk_every(128)
        |> Enum.reduce({0, 0, Decimal.new("0")}, fn batch, {count, tokens, cost} ->
          Mix.shell().info("  Embedding batch #{div(count, 128) + 1} (#{length(batch)} nodes)...")

          case VoyageEmbedder.embed_keyed(batch) do
            {:ok, keyed, usage} ->
              Enum.each(keyed, fn {id, embedding} ->
                case Nodes.set_embedding(id, embedding) do
                  :ok ->
                    :ok

                  {:error, reason} ->
                    Mix.shell().error("  Failed to store embedding for #{id}: #{inspect(reason)}")
                end
              end)

              {count + length(keyed), tokens + usage.total_tokens,
               Decimal.add(cost, usage.cost_usd)}

            {:error, :voyage_api_key_not_configured} ->
              Mix.shell().error("VOYAGE_API_KEY is not set. Set it and retry.")
              System.halt(1)

            {:error, reason} ->
              Mix.shell().error("  Batch failed: #{inspect(reason)}")
              {count, tokens, cost}
          end
        end)

      Mix.shell().info("""

      Done.
        Nodes embedded : #{embedded} / #{total}
        Total tokens   : #{total_tokens}
        Estimated cost : $#{Decimal.round(total_cost, 6)}
      """)
    end
  end

  defp resolve_graph_ids(nil) do
    # All graphs — fetch from Postgres
    Xwa.Repo.all(Xwa.Graphs.Graph) |> Enum.map(& &1.id)
  end

  defp resolve_graph_ids(graph_id), do: [graph_id]
end
