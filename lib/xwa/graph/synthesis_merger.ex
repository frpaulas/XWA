defmodule Xwa.Graph.SynthesisMerger do
  @moduledoc """
  Merges near-duplicate cross-graph claim nodes into synthesis nodes.

  A synthesis node is a new `:Claim` with `node_type: "synthesis"` that
  holds a Claude-generated canonical claim distilled from 2+ semantically
  near-identical nodes coming from different graphs. The originals are
  preserved; `contributes_to` edges connect them to the synthesis node.

  ## Pipeline

      {:ok, sns} = SynthesisMerger.merge_graphs(graph_id_a, graph_id_b,
                     composite_graph_id,
                     created_by: user_id)

  Internally:
  1. `SimilarityMerger.find_similar_pairs/3` — cosine similarity at ≥ 0.95
  2. `SimilarityMerger.cluster_pairs/1`      — union-find grouping
  3. Per cluster: Claude generates a canonical claim
  4. Synthesis node created in `composite_graph_id`
  5. `contributes_to` edges from each constituent to the synthesis node

  ## Cost

  One short Claude API call (~200 input + ~150 output tokens) per synthesis
  cluster. For typical merge runs with <20 clusters this is well under $0.01.
  """

  require Logger

  alias Xwa.Graph.{Nodes, Edges, SimilarityMerger}
  alias Xwa.Graph.Node

  @synthesis_threshold 0.95

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Identifies near-duplicate cross-graph claim clusters and creates a synthesis
  node in `composite_graph_id` for each cluster.

  Options:
    - `:threshold`   — cosine similarity threshold (default: #{@synthesis_threshold})
    - `:created_by`  — user UUID to attribute synthesis nodes to

  Returns `{:ok, [%Node{}]}` — the list of created synthesis nodes.
  Returns `{:error, :embeddings_missing}` if either graph has no embeddings.
  """
  @spec merge_graphs(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [Node.t()]} | {:error, term()}
  def merge_graphs(graph_id_a, graph_id_b, composite_graph_id, opts \\ []) do
    threshold = Keyword.get(opts, :threshold, @synthesis_threshold)
    created_by = Keyword.get(opts, :created_by)

    with {:ok, pairs} <-
           SimilarityMerger.find_similar_pairs(graph_id_a, graph_id_b, threshold: threshold) do
      clusters = SimilarityMerger.cluster_pairs(pairs)

      Logger.info(
        "[SynthesisMerger] #{length(clusters)} cluster(s) to synthesize " <>
          "from #{length(pairs)} near-duplicate pair(s)"
      )

      synthesis_nodes =
        clusters
        |> Enum.flat_map(fn cluster ->
          case synthesize_cluster(cluster, composite_graph_id, created_by) do
            {:ok, sn} ->
              Logger.info("[SynthesisMerger] Created synthesis node #{sn.id} from #{length(cluster)} constituents")
              [sn]

            {:error, reason} ->
              Logger.warning("[SynthesisMerger] Failed to synthesize cluster #{inspect(cluster)}: #{inspect(reason)}")
              []
          end
        end)

      {:ok, synthesis_nodes}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp synthesize_cluster(node_ids, composite_graph_id, created_by) do
    nodes =
      node_ids
      |> Enum.flat_map(fn id ->
        case Nodes.get(id) do
          {:ok, nil} -> []
          {:ok, node} -> [node]
          {:error, _} -> []
        end
      end)

    if length(nodes) < 2 do
      {:error, :insufficient_nodes}
    else
      with {:ok, attrs, _usage} <- call_claude(nodes) do
        constituents = Enum.map(nodes, fn n -> %{node_id: n.id, graph_id: n.graph_id} end)

        node_attrs =
          Map.merge(attrs, %{
            node_type: "synthesis",
            constituents: constituents,
            graph_id: composite_graph_id,
            created_by: created_by,
            ai_inferred: true,
            human_validated: false,
            visibility: "system"
          })

        with {:ok, sn} <- Nodes.create(node_attrs) do
          Enum.each(nodes, fn constituent ->
            edge_attrs = %{
              from_node_id: constituent.id,
              to_node_id: sn.id,
              type: "contributes_to",
              graph_id: composite_graph_id,
              created_by: created_by,
              ai_inferred: true,
              confidence: 1.0,
              certainty: "solid",
              source_document_ids: [],
              visibility: "system"
            }

            case Edges.create(edge_attrs) do
              {:ok, _} ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "[SynthesisMerger] Failed to create contributes_to edge " <>
                    "#{constituent.id}->#{sn.id}: #{inspect(reason)}"
                )
            end
          end)

          {:ok, sn}
        end
      end
    end
  end

  defp call_claude(nodes) do
    api_key =
      Application.get_env(:xwa, :anthropic_api_key) ||
        System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      {:error, :anthropic_api_key_not_configured}
    else
      numbered =
        nodes
        |> Enum.with_index(1)
        |> Enum.map_join("\n", fn {n, i} -> "#{i}. #{n.content}" end)

      prompt = """
      You are synthesizing #{length(nodes)} near-duplicate knowledge graph claims into a single canonical claim.

      These claims were identified as semantically near-identical (cosine similarity ≥ 0.95) but originate from different graphs or authors.

      Claims:
      #{numbered}

      Return a JSON object with exactly these keys:
      - "content": The synthesized canonical claim (1–3 sentences, comprehensive, no author attribution)
      - "summary": A brief one-sentence summary (max 15 words)
      - "type": The semantic type of the claim (infer from input claims, e.g. "belief", "fact", "goal")
      - "confidence": Your confidence in the synthesis as a float 0.0–1.0

      Return only the JSON object, no markdown fences.
      """

      body = %{
        model: model(),
        max_tokens: 512,
        messages: [%{role: "user", content: prompt}]
      }

      t0 = System.monotonic_time(:millisecond)

      result =
        Req.post("https://api.anthropic.com/v1/messages",
          json: body,
          headers: [
            {"x-api-key", api_key},
            {"anthropic-version", "2023-06-01"}
          ],
          receive_timeout: 30_000
        )

      latency_ms = System.monotonic_time(:millisecond) - t0

      case result do
        {:ok, %{status: 200, body: resp_body}} ->
          usage = %{
            input_tokens: get_in(resp_body, ["usage", "input_tokens"]),
            output_tokens: get_in(resp_body, ["usage", "output_tokens"]),
            latency_ms: latency_ms,
            model: resp_body["model"] || model()
          }

          with {:ok, text} <- extract_text(resp_body),
               {:ok, attrs} <- parse_response(text) do
            {:ok, attrs, usage}
          end

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:api_error, status, resp_body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end
  end

  defp extract_text(%{"content" => [%{"text" => text} | _]}), do: {:ok, text}
  defp extract_text(body), do: {:error, {:unexpected_response, body}}

  defp parse_response(text) do
    json_str =
      case Regex.run(~r/```(?:json)?\s*([\s\S]*?)```/m, text, capture: :all_but_first) do
        [json] -> String.trim(json)
        nil -> String.trim(text)
      end

    case Jason.decode(json_str) do
      {:ok, %{"content" => content, "summary" => summary} = parsed}
      when is_binary(content) and is_binary(summary) ->
        {:ok,
         %{
           content: content,
           summary: summary,
           type: parsed["type"],
           confidence: parsed["confidence"] || 1.0
         }}

      {:ok, _} ->
        {:error, :missing_required_keys}

      {:error, reason} ->
        {:error, {:json_parse_error, reason}}
    end
  end

  defp model do
    Application.get_env(
      :xwa,
      :claude_synthesis_model,
      Application.get_env(:xwa, :claude_model, "claude-sonnet-4-6")
    )
  end
end
