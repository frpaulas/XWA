defmodule Xwa.Ingestion.NliGate do
  @moduledoc """
  Filters candidate nodes using the local NLI sidecar service.

  Scores (new_claim, candidate) pairs via `cross-encoder/nli-deberta-v3-small`
  running on localhost:8765. Drops pairs where the neutral score exceeds
  `@neutral_threshold`, keeping only entailment and contradiction candidates.

  Falls back gracefully to `Enum.take(candidates, keep)` if the service is
  unavailable — ingestion continues uninterrupted.

  ## Typical usage in IngestionWorker

      candidates_50 = cosine_top_n(graph, embedding, 50)
      candidates_20 = NliGate.filter(claim_text, candidates_50, keep: 20)
      EdgeExtractor.extract(node, candidates_20, context)
  """

  require Logger

  @service_url "http://127.0.0.1:8765"
  @timeout_ms 8_000
  # Drop a pair when neutral probability exceeds this threshold.
  # 0.5 = drop majority-neutral pairs; lower = stricter.
  @neutral_threshold 0.6

  @doc """
  Filters `candidates` (list of `%Node{}`) down to at most `keep` nodes that
  have a non-neutral NLI relationship with `claim_text`.

  Options:
  - `:keep` — max candidates to return (default 20)
  """
  @spec filter(String.t(), list(), keyword()) :: list()
  def filter(claim_text, candidates, opts \\ []) when is_binary(claim_text) and is_list(candidates) do
    keep = Keyword.get(opts, :keep, 20)

    if candidates == [] do
      []
    else
      pairs = Enum.map(candidates, fn c ->
        [claim_text, c.summary || c.content || ""]
      end)

      case score_pairs(pairs) do
        {:ok, scores} ->
          scored = Enum.zip(candidates, scores)

          filtered =
            scored
            |> Enum.reject(fn {_c, s} -> Map.get(s, "neutral", 0.0) > @neutral_threshold end)
            |> Enum.sort_by(fn {_c, s} ->
              max(Map.get(s, "entailment", 0.0), Map.get(s, "contradiction", 0.0))
            end, :desc)
            |> Enum.take(keep)
            |> Enum.map(fn {c, _s} -> c end)

          # Floor guarantee: if NLI filtered too aggressively, pad with best cosine candidates
          if length(filtered) >= keep do
            filtered
          else
            already = MapSet.new(filtered, & &1.id)
            extras =
              scored
              |> Enum.map(fn {c, _} -> c end)
              |> Enum.reject(&MapSet.member?(already, &1.id))
              |> Enum.take(keep - length(filtered))
            filtered ++ extras
          end

        {:error, reason} ->
          Logger.warning("[NliGate] Unavailable (#{inspect(reason)}) — falling back to top-#{keep}")
          Enum.take(candidates, keep)
      end
    end
  end

  @doc """
  Returns `true` if the NLI sidecar is running and healthy.
  """
  @spec available?() :: boolean()
  def available? do
    case Req.get("#{@service_url}/health", receive_timeout: 2_000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------

  defp score_pairs(pairs) do
    case Req.post("#{@service_url}/score",
      json: %{pairs: pairs},
      receive_timeout: @timeout_ms
    ) do
      {:ok, %{status: 200, body: %{"scores" => scores}}} ->
        {:ok, scores}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
