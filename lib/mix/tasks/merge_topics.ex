defmodule Mix.Tasks.MergeTopics do
  @moduledoc """
  Clusters existing over-split topic nodes by cosine similarity and merges
  each cluster into a single representative topic.

  For each cluster:
  - Keeps the topic node whose label will become the canonical label
    (shortest label wins — it's usually the broadest)
  - Re-points all BELONGS_TO edges from merged nodes to the kept node
  - Deletes the merged (redundant) topic nodes

  ## Usage

      mix merge_topics                        # dry run — prints clusters only
      mix merge_topics --apply               # actually merges
      mix merge_topics --threshold 0.78      # override similarity threshold (default 0.78)

  Run with --apply only after reviewing the --dry-run output.
  """

  use Mix.Task
  require Logger

  alias Xwa.Graph
  alias Xwa.Graph.{Nodes, VectorMath}

  @shortdoc "Cluster and merge over-split topic nodes by cosine similarity"

  @default_threshold 0.74

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} = OptionParser.parse!(args, strict: [apply: :boolean, threshold: :float])
    apply? = Keyword.get(opts, :apply, false)
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    Mix.shell().info("Loading all topic nodes...")

    {:ok, rows} = Graph.query(
      "MATCH (n:Claim {node_type: 'topic'}) WHERE n.embedding IS NOT NULL RETURN n",
      %{}
    )

    topics = Enum.map(rows, fn %{"n" => bolt} -> Xwa.Graph.Node.from_bolt(bolt) end)
    Mix.shell().info("Found #{length(topics)} topics with embeddings.")

    if length(topics) < 2 do
      Mix.shell().info("Nothing to merge.")
    else
      clusters = cluster(topics, threshold)
      multi = Enum.filter(clusters, fn c -> length(c) > 1 end)
      single = length(clusters) - length(multi)

      Mix.shell().info("Clusters at threshold #{threshold}:")
      Mix.shell().info("  #{length(multi)} clusters to merge (#{multi |> Enum.map(&length/1) |> Enum.sum()} topics → #{length(multi)} topics)")
      Mix.shell().info("  #{single} singleton topics (unchanged)")
      Mix.shell().info("")

      Enum.each(multi, fn cluster ->
        {keep, merge} = pick_representative(cluster)
        Mix.shell().info("MERGE → \"#{keep.content}\"")
        Enum.each(merge, fn t -> Mix.shell().info("  ← \"#{t.content}\"") end)
      end)

      redundant_count = multi |> Enum.map(&length/1) |> Enum.sum() |> Kernel.-(length(multi))
      Mix.shell().info("\nTotal: #{length(topics)} topics → #{length(topics) - redundant_count} after merge (#{redundant_count} removed)")

      if apply? do
        Mix.shell().info("\nApplying merges...")
        Enum.each(multi, fn cluster ->
          {keep, merge} = pick_representative(cluster)
          do_merge(keep, merge)
        end)
        Mix.shell().info("Done.")
      else
        Mix.shell().info("Dry run — pass --apply to execute.")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Clustering (greedy single-linkage)
  # ---------------------------------------------------------------------------

  defp cluster(topics, threshold) do
    # Pre-normalize once
    normed = Enum.map(topics, fn t -> {t, VectorMath.normalize(t.embedding)} end)

    # Complete-linkage: a topic joins a cluster only if it is >= threshold
    # with EVERY existing member (not just one). This prevents chaining.
    Enum.reduce(normed, [], fn {topic, norm}, clusters ->
      idx = Enum.find_index(clusters, fn cluster ->
        Enum.all?(cluster, fn {_t, cn} ->
          VectorMath.dot_product(norm, cn) >= threshold
        end)
      end)

      if idx do
        List.update_at(clusters, idx, fn cluster -> [{topic, norm} | cluster] end)
      else
        clusters ++ [[{topic, norm}]]
      end
    end)
    |> Enum.map(fn cluster -> Enum.map(cluster, fn {t, _} -> t end) end)
  end

  # Keep the shortest label (most general); merge the rest.
  defp pick_representative(cluster) do
    sorted = Enum.sort_by(cluster, fn t -> String.length(t.content) end)
    [keep | merge] = sorted
    {keep, merge}
  end

  # ---------------------------------------------------------------------------
  # Merge execution
  # ---------------------------------------------------------------------------

  defp do_merge(keep, merge_list) do
    Enum.each(merge_list, fn redundant ->
      # Re-point all BELONGS_TO edges from redundant → keep
      repoint_cypher = """
      MATCH (c:Claim)-[old:RELATES {type: "belongs_to", to_node_id: $old_id}]->(t:Claim {id: $old_id})
      MATCH (keep:Claim {id: $keep_id})
      MERGE (c)-[new:RELATES {type: "belongs_to", from_node_id: c.id, to_node_id: $keep_id, graph_id: old.graph_id}]->(keep)
      ON CREATE SET
        new.id            = $new_edge_id,
        new.created_by    = old.created_by,
        new.visibility    = "system",
        new.confidence    = 1.0,
        new.importance    = 0.5,
        new.certainty     = "solid",
        new.directed      = true,
        new.ai_inferred   = true,
        new.human_validated = false,
        new.contested     = false,
        new.source_document_ids = []
      DELETE old
      """

      case Graph.run(repoint_cypher, %{
        old_id: redundant.id,
        keep_id: keep.id,
        new_edge_id: Ecto.UUID.generate()
      }) do
        :ok -> :ok
        {:error, reason} ->
          Logger.warning("[MergeTopics] Failed to repoint edges for #{redundant.id}: #{inspect(reason)}")
      end

      # Delete the redundant topic node (detach in case any other edges remain)
      Graph.run("MATCH (n:Claim {id: $id}) DETACH DELETE n", %{id: redundant.id})
    end)
  end
end
