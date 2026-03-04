defmodule Xwa.Graph.SimilarityMerger do
  @moduledoc """
  Finds semantically similar node pairs across two graphs using cosine
  similarity of their Voyage AI embeddings.

  This is the core of the low-cost merge strategy: instead of asking Claude
  to evaluate every cross-graph node pair (expensive), we compute dot products
  between pre-stored embedding vectors (free after one-time embedding cost).

  ## Usage

      {:ok, pairs} = SimilarityMerger.find_similar_pairs(graph_id_a, graph_id_b)
      # pairs: [%{node_a: id, node_b: id, score: 0.94}, ...]  sorted by score desc

      # With custom threshold
      {:ok, pairs} = SimilarityMerger.find_similar_pairs(graph_id_a, graph_id_b,
        threshold: 0.90
      )

  ## Thresholds

  Recommended starting points:
    - 0.95+  Near-identical claims (same fact, slightly different wording)
    - 0.90+  Strongly related claims (same topic, different perspective)
    - 0.85+  Loosely related claims (shared theme)

  Start conservative (0.92) and lower if too few matches surface.

  ## Performance

  For N nodes in graph A and M nodes in graph B:
    - Computation: O(N × M × D) where D = embedding dimension (1024)
    - Parallelized across CPU cores via Task.async_stream
    - 1400 × 246 pairs ≈ 1-3 seconds on a modern machine
    - No API calls — pure Elixir arithmetic on stored vectors
  """

  require Logger

  alias Xwa.Graph.Nodes

  @default_threshold 0.92
  # Number of node-rows from graph_a to process concurrently
  @parallel_chunk 50

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns cross-graph node pairs whose cosine similarity exceeds `threshold`.

  Options:
    - `:threshold` — float in [0, 1], default #{@default_threshold}
    - `:limit`     — max pairs to return (default: all above threshold)

  Returns `{:error, :embeddings_missing}` if either graph has no embeddings.
  """
  @spec find_similar_pairs(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def find_similar_pairs(graph_id_a, graph_id_b, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @default_threshold)
    limit = Keyword.get(opts, :limit, :infinity)

    with {:ok, pairs_a} <- Nodes.list_embeddings(graph_id_a),
         {:ok, pairs_b} <- Nodes.list_embeddings(graph_id_b) do
      if pairs_a == [] or pairs_b == [] do
        Logger.warning(
          "[SimilarityMerger] One or both graphs have no embeddings. " <>
            "Run `mix backfill_embeddings` first."
        )
        {:error, :embeddings_missing}
      else
        Logger.info(
          "[SimilarityMerger] Computing similarity: #{length(pairs_a)} × #{length(pairs_b)} pairs"
        )

        # Pre-normalize all embeddings once to speed up dot products
        normalized_a = Enum.map(pairs_a, fn {id, emb} -> {id, normalize(emb)} end)
        normalized_b = Enum.map(pairs_b, fn {id, emb} -> {id, normalize(emb)} end)

        results =
          normalized_a
          |> Enum.chunk_every(@parallel_chunk)
          |> Task.async_stream(
            fn chunk ->
              Enum.flat_map(chunk, fn {id_a, emb_a} ->
                Enum.flat_map(normalized_b, fn {id_b, emb_b} ->
                  score = dot_product(emb_a, emb_b)
                  if score >= threshold, do: [%{node_a: id_a, node_b: id_b, score: score}], else: []
                end)
              end)
            end,
            ordered: false,
            timeout: 60_000
          )
          |> Enum.flat_map(fn {:ok, chunk_results} -> chunk_results end)
          |> Enum.sort_by(& &1.score, :desc)

        results =
          case limit do
            :infinity -> results
            n -> Enum.take(results, n)
          end

        Logger.info("[SimilarityMerger] Found #{length(results)} pairs above threshold #{threshold}")
        {:ok, results}
      end
    end
  end

  @doc """
  Groups similar-pair results into clusters using union-find.

  Treats each pair as an undirected edge; connected components become
  clusters. Returns only clusters with 2+ members — singletons are not
  candidates for synthesis.

  ## Example

      pairs = [
        %{node_a: "a1", node_b: "b1", score: 0.97},
        %{node_a: "a1", node_b: "b2", score: 0.96}
      ]
      SimilarityMerger.cluster_pairs(pairs)
      # => [["a1", "b1", "b2"]]
  """
  @spec cluster_pairs([map()]) :: [[String.t()]]
  def cluster_pairs(pairs) do
    all_ids =
      pairs
      |> Enum.flat_map(fn %{node_a: a, node_b: b} -> [a, b] end)
      |> Enum.uniq()

    parent = Map.new(all_ids, fn id -> {id, id} end)

    parent =
      Enum.reduce(pairs, parent, fn %{node_a: a, node_b: b}, acc ->
        uf_union(acc, a, b)
      end)

    all_ids
    |> Enum.group_by(fn id -> uf_find(parent, id) end)
    |> Map.values()
    |> Enum.filter(fn cluster -> length(cluster) >= 2 end)
  end

  # ---------------------------------------------------------------------------
  # Private math
  # ---------------------------------------------------------------------------

  defp uf_find(parent, id) do
    if parent[id] == id, do: id, else: uf_find(parent, parent[id])
  end

  defp uf_union(parent, a, b) do
    root_a = uf_find(parent, a)
    root_b = uf_find(parent, b)
    if root_a == root_b, do: parent, else: Map.put(parent, root_a, root_b)
  end

  # Normalize a vector to unit length. Pre-normalizing means dot product = cosine similarity.
  defp normalize(vec) do
    magnitude = :math.sqrt(Enum.reduce(vec, 0.0, fn x, acc -> acc + x * x end))
    if magnitude == 0.0, do: vec, else: Enum.map(vec, fn x -> x / magnitude end)
  end

  # Dot product of two pre-normalized vectors = cosine similarity.
  defp dot_product(a, b) do
    Enum.zip_reduce(a, b, 0.0, fn x, y, acc -> acc + x * y end)
  end
end
