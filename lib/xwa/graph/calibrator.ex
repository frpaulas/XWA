defmodule Xwa.Graph.Calibrator do
  @moduledoc """
  ILV corpus calibration algorithm.

  ## Algorithm — O(2N) API calls

  Because the ILV API's normalization is linear:

      FP(text, GFP)[d] = raw[d] - GFP[d] + 0.5

  We can separate the work into two phases with pure-math convergence between
  them, avoiding the O(N²) re-call loop.

  ### Phase 1 — Score all claims (N API calls)
  Call the ILV API with initial GFP = `{0.5, 0.5, 0.5, 0.5}`.  Because
  `GFP[d] - 0.5 = 0`, the returned FP equals the raw (corpus-independent) FP.
  Cache as `raw_fps`.

  ### Convergence — pure math, zero API calls
  The optimal GFP is `mean(raw_fps)`.  Iterate:
  1. `new_GFP = mean(raw_fps)`
  2. If `max |new_GFP[d] - GFP[d]| < 0.01` → done
  3. `GFP = new_GFP`, repeat

  Since `raw_fps` are constant, this converges in ≤ 2 iterations.

  ### Phase 2 — Re-score with converged GFP (N API calls)
  Call the ILV API again with the converged GFP to obtain corpus-normalized
  scores and fingerprints.  Store both on each Claim node.

  ## New-claim drift protection
  After calibration is complete, new claims arriving via ingestion are scored
  individually against the stored GFP.  If a new claim's raw FP would shift
  the GFP by > 0.01 in any dimension, it is flagged (`ilv_score = nil`,
  `ilv_fingerprint = nil`) and not incorporated until the next explicit
  recalibration.
  """

  require Logger

  alias Xwa.Graph.Nodes
  alias Xwa.Graphs
  alias Xwa.Ingestion.IlvScorer

  @dims [:w, :x, :y, :z]
  @concurrency 50

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Runs the full calibration pipeline for a graph.

  Broadcasts progress via PubSub on `"graph:\#{graph_id}"` (unless
  `broadcast: false` is passed in opts).

  Returns `{:ok, %{gfp: map, scored: integer, iterations: integer}}`
  or `{:error, reason}`.
  """
  @spec calibrate(String.t(), keyword()) ::
          {:ok, %{gfp: map(), scored: non_neg_integer(), iterations: non_neg_integer()}}
          | {:error, any()}
  def calibrate(graph_id, opts \\ []) do
    broadcast = Keyword.get(opts, :broadcast, true)

    with {:ok, claims} <- Nodes.list_all_claims(graph_id),
         total = length(claims),
         _ <- broadcast(broadcast, graph_id, {:calibration_progress, :started, %{total: total}}),
         {:ok, raw_fps} <- phase1(claims, broadcast, graph_id),
         {api_gfp, stored_gfp, iterations} <- converge(raw_fps),
         _ <- broadcast(broadcast, graph_id, {:calibration_progress, :phase2_start, %{gfp: api_gfp, iterations: iterations}}),
         {:ok, scored} <- phase2(claims, api_gfp, stored_gfp, broadcast, graph_id),
         {:ok, _graph} <- Graphs.update_fingerprint(graph_id, stringify_fp(stored_gfp)) do
      broadcast(broadcast, graph_id, {:calibration_complete, %{gfp: api_gfp, scored: scored, iterations: iterations}})
      {:ok, %{gfp: api_gfp, scored: scored, iterations: iterations}}
    else
      {:error, reason} = err ->
        broadcast(broadcast, graph_id, {:calibration_failed, reason})
        err
    end
  end

  @doc """
  Scores a single new claim against the graph's stored GFP.

  Returns `{:ok, %{score: float, fingerprint: map, drifts: boolean}}`.
  `drifts: true` means this claim would shift the corpus GFP by > threshold
  and should be flagged rather than treated as calibrated.
  """
  @spec score_new_claim(String.t(), String.t(), map()) ::
          {:ok, %{score: float(), fingerprint: map(), drifts: boolean()}} | {:error, any()}
  def score_new_claim(claim_id, content, gfp) do
    api_gfp = flatten_gfp(gfp)
    case IlvScorer.score(content, api_gfp) do
      {:ok, %{score: score, fingerprint: fp}} ->
        raw_fp = to_raw_fp(fp, api_gfp)
        drifts = would_drift?(api_gfp, raw_fp)
        {:ok, %{score: score, fingerprint: fp, drifts: drifts}}

      {:error, reason} ->
        Logger.warning("[Calibrator] score_new_claim failed for #{claim_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Phase 1 — N parallel API calls, GFP = initial {0.5, 0.5, 0.5, 0.5}
  # ---------------------------------------------------------------------------

  defp phase1(claims, broadcast, graph_id) do
    initial = IlvScorer.initial_gfp()
    total = length(claims)
    done_ref = :counters.new(1, [])

    pairs =
      claims
      |> Task.async_stream(
        fn %{id: id, content: content} ->
          case IlvScorer.score(content, initial) do
            {:ok, %{fingerprint: fp}} -> {:ok, {id, fp}}
            {:error, reason} -> {:error, {id, reason}}
          end
        end,
        max_concurrency: @concurrency,
        ordered: false,
        timeout: 60_000,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, {id, fp}}} ->
          done = :counters.add(done_ref, 1, 1) |> then(fn _ -> :counters.get(done_ref, 1) end)
          broadcast(broadcast, graph_id, {:calibration_progress, :phase1, %{done: done, total: total}})
          [{id, fp}]

        {:ok, {:error, {id, reason}}} ->
          Logger.warning("[Calibrator] phase1 failed for #{id}: #{inspect(reason)}")
          []

        {:exit, reason} ->
          Logger.warning("[Calibrator] phase1 task crashed: #{inspect(reason)}")
          []
      end)

    {:ok, pairs}
  end

  # ---------------------------------------------------------------------------
  # Convergence — pure math, O(iterations) ≤ 2 in practice
  # ---------------------------------------------------------------------------

  defp converge(pairs) do
    raw_fps = Enum.map(pairs, fn {_id, fp} -> fp end)
    do_converge(raw_fps, IlvScorer.initial_gfp(), 0)
  end

  # Returns {api_gfp, stored_gfp, iterations}
  # api_gfp  — flat %{w: median, ...} for ILV API calls
  # stored_gfp — nested %{w: %{median: m, sd: s}, ...} for Postgres
  defp do_converge(raw_fps, gfp, iter) do
    new_median_gfp = median_fps(raw_fps)

    if stable?(gfp, new_median_gfp) do
      sd = sd_fps(raw_fps, new_median_gfp)
      stored_gfp = Map.new(@dims, fn d -> {d, %{median: Map.get(new_median_gfp, d), sd: Map.get(sd, d)}} end)
      Logger.info("[Calibrator] GFP converged in #{iter + 1} iteration(s): #{inspect(new_median_gfp)}")
      {new_median_gfp, stored_gfp, iter + 1}
    else
      do_converge(raw_fps, new_median_gfp, iter + 1)
    end
  end

  defp stable?(old_gfp, new_gfp) do
    threshold = IlvScorer.convergence_threshold()
    Enum.all?(@dims, fn d -> abs(Map.get(old_gfp, d, 0.5) - Map.get(new_gfp, d, 0.5)) < threshold end)
  end

  # Median per axis from a list of fingerprint maps.
  defp median_fps(fps) do
    Map.new(@dims, fn d ->
      sorted = fps |> Enum.map(&Map.get(&1, d, 0.5)) |> Enum.sort()
      n = length(sorted)
      median =
        if rem(n, 2) == 0 do
          (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2.0
        else
          Enum.at(sorted, div(n, 2))
        end
      {d, median}
    end)
  end

  # Population standard deviation around the median per axis.
  defp sd_fps(fps, median_gfp) do
    n = length(fps)
    Map.new(@dims, fn d ->
      center = Map.get(median_gfp, d, 0.5)
      variance = Enum.reduce(fps, 0.0, fn fp, acc ->
        diff = Map.get(fp, d, 0.5) - center
        acc + diff * diff
      end) / n
      {d, :math.sqrt(variance)}
    end)
  end

  # ---------------------------------------------------------------------------
  # Phase 2 — N parallel API calls with converged GFP; store results
  # ---------------------------------------------------------------------------

  defp phase2(claims, gfp, stored_gfp, broadcast, graph_id) do
    total = length(claims)
    done_ref = :counters.new(1, [])

    scored =
      claims
      |> Task.async_stream(
        fn %{id: id, content: content, confidence: base_conf} ->
          case IlvScorer.score(content, gfp) do
            {:ok, %{score: score, fingerprint: fp}} ->
              sfms = compute_sfms(fp, stored_gfp)
              adj_conf = adjusted_confidence(base_conf, score, sfms)
              g_flag = gaming_flag?(sfms)
              {:ok, {id, score * 1.0, fp, adj_conf, g_flag}}

            {:error, reason} ->
              {:error, {id, reason}}
          end
        end,
        max_concurrency: @concurrency,
        ordered: false,
        timeout: 60_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(0, fn
        {:ok, {:ok, {id, score, fp, adj_conf, g_flag}}}, count ->
          case Nodes.set_ilv(id, score, fp, adj_conf, g_flag) do
            :ok ->
              done = :counters.add(done_ref, 1, 1) |> then(fn _ -> :counters.get(done_ref, 1) end)
              broadcast(broadcast, graph_id, {:calibration_progress, :phase2, %{done: done, total: total}})
              count + 1

            {:error, reason} ->
              Logger.warning("[Calibrator] set_ilv failed for #{id}: #{inspect(reason)}")
              count
          end

        {:ok, {:error, {id, reason}}}, count ->
          Logger.warning("[Calibrator] phase2 score failed for #{id}: #{inspect(reason)}")
          count

        {:exit, reason}, count ->
          Logger.warning("[Calibrator] phase2 task crashed: #{inspect(reason)}")
          count
      end)

    {:ok, scored}
  end

  # ---------------------------------------------------------------------------
  # SFM / confidence / gaming computations
  # ---------------------------------------------------------------------------

  # σ from median for each axis: (cfp[d] - 0.5) / sd[d]
  # stored_gfp has atom keys: %{w: %{median: f, sd: f}, ...}
  defp compute_sfms(fp, stored_gfp) do
    Map.new(@dims, fn d ->
      cfp_val = Map.get(fp, d) || Map.get(fp, to_string(d)) || 0.5
      entry = Map.get(stored_gfp, d)
      sd = if is_map(entry), do: entry.sd, else: nil
      sfm = if sd && sd > 0, do: (cfp_val - 0.5) / sd, else: 0.0
      {d, sfm}
    end)
  end

  # Confidence = (0.4 × normalized_base + 0.6 × ilv_score) × (1 - neg_penalty)
  # ILV drives most of the score; Claude's extraction confidence is a secondary modifier.
  # base_conf from Claude is in [0.6, 1.0]; normalize to [0.2, 1.0] so the minimum
  # passing claim has a floor of 0.2 rather than 0.0 (fairer visual representation).
  # neg_penalty = Σ max(0, -sfm[d]) × 0.08, capped at 0.8 so confidence never zeroes out
  defp adjusted_confidence(base_conf, ilv_score, sfms) do
    normalized_base = 0.2 + (base_conf - 0.6) * 2.0

    neg_penalty =
      sfms
      |> Map.values()
      |> Enum.reduce(0.0, fn sfm, acc -> acc + max(0.0, -sfm) * 0.08 end)
      |> min(0.8)

    blended = 0.4 * normalized_base + 0.6 * ilv_score

    (blended * (1.0 - neg_penalty))
    |> max(0.0)
    |> min(1.0)
  end

  # Gaming flag: net-positive SFM but a significant negative outlier on one axis.
  # gaming_score = max(0, mean_sfm) × max(0, -min_sfm); flag when > 0.3
  defp gaming_flag?(sfms) do
    vals = Map.values(sfms)
    mean_sfm = Enum.sum(vals) / length(vals)
    min_sfm = Enum.min(vals)
    max(0.0, mean_sfm) * max(0.0, -min_sfm) > 0.3
  end

  # ---------------------------------------------------------------------------
  # Drift detection for new claims
  # ---------------------------------------------------------------------------

  # Extract flat %{w: median, ...} from either a flat or nested GFP map.
  defp flatten_gfp(gfp) do
    Map.new(@dims, fn d ->
      val = Map.get(gfp, d) || Map.get(gfp, to_string(d))
      median = if is_map(val), do: (val["median"] || Map.get(val, :median) || 0.5), else: (val || 0.5)
      {d, median}
    end)
  end

  # Recover raw FP from a scored FP and GFP using the linear relationship.
  defp to_raw_fp(fp, gfp) do
    Map.new(@dims, fn d ->
      {d, Map.get(fp, d, 0.5) + Map.get(gfp, d, 0.5) - 0.5}
    end)
  end

  # Would incorporating this raw_fp shift the current GFP beyond threshold?
  # We approximate: if the raw_fp differs from gfp by > threshold in any dim,
  # adding it to the corpus could meaningfully shift the centroid.
  defp would_drift?(gfp, raw_fp) do
    threshold = IlvScorer.convergence_threshold()
    Enum.any?(@dims, fn d -> abs(Map.get(raw_fp, d, 0.5) - Map.get(gfp, d, 0.5)) > threshold end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp stringify_fp(fp) when is_map(fp) do
    Map.new(fp, fn {k, v} ->
      val = if is_map(v), do: Map.new(v, fn {ik, iv} -> {to_string(ik), iv} end), else: v
      {to_string(k), val}
    end)
  end

  defp broadcast(true, graph_id, message) do
    Phoenix.PubSub.broadcast(Xwa.PubSub, "graph:#{graph_id}", message)
  end

  defp broadcast(false, _graph_id, _message), do: :ok
end
