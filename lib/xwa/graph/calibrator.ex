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
  @concurrency 10

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
         {gfp, iterations} <- converge(raw_fps),
         _ <- broadcast(broadcast, graph_id, {:calibration_progress, :phase2_start, %{gfp: gfp, iterations: iterations}}),
         {:ok, scored} <- phase2(claims, gfp, broadcast, graph_id),
         {:ok, _graph} <- Graphs.update_fingerprint(graph_id, stringify_fp(gfp)) do
      broadcast(broadcast, graph_id, {:calibration_complete, %{gfp: gfp, scored: scored, iterations: iterations}})
      {:ok, %{gfp: gfp, scored: scored, iterations: iterations}}
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
    case IlvScorer.score(content, gfp) do
      {:ok, %{score: score, fingerprint: fp}} ->
        raw_fp = to_raw_fp(fp, gfp)
        drifts = would_drift?(gfp, raw_fp)
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
        timeout: 30_000
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

  defp do_converge(raw_fps, gfp, iter) do
    new_gfp = mean_fps(raw_fps)

    if stable?(gfp, new_gfp) do
      Logger.info("[Calibrator] GFP converged in #{iter + 1} iteration(s): #{inspect(new_gfp)}")
      {new_gfp, iter + 1}
    else
      do_converge(raw_fps, new_gfp, iter + 1)
    end
  end

  defp stable?(old_gfp, new_gfp) do
    threshold = IlvScorer.convergence_threshold()
    Enum.all?(@dims, fn d -> abs(Map.get(old_gfp, d, 0.5) - Map.get(new_gfp, d, 0.5)) < threshold end)
  end

  defp mean_fps(fps) do
    n = length(fps)

    fps
    |> Enum.reduce(%{w: 0.0, x: 0.0, y: 0.0, z: 0.0}, fn fp, acc ->
      %{
        w: acc.w + Map.get(fp, :w, 0.5),
        x: acc.x + Map.get(fp, :x, 0.5),
        y: acc.y + Map.get(fp, :y, 0.5),
        z: acc.z + Map.get(fp, :z, 0.5)
      }
    end)
    |> Map.new(fn {d, sum} -> {d, sum / n} end)
  end

  # ---------------------------------------------------------------------------
  # Phase 2 — N parallel API calls with converged GFP; store results
  # ---------------------------------------------------------------------------

  defp phase2(claims, gfp, broadcast, graph_id) do
    total = length(claims)
    done_ref = :counters.new(1, [])

    scored =
      claims
      |> Task.async_stream(
        fn %{id: id, content: content} ->
          case IlvScorer.score(content, gfp) do
            {:ok, %{score: score, fingerprint: fp}} -> {:ok, {id, score * 1.0, fp}}
            {:error, reason} -> {:error, {id, reason}}
          end
        end,
        max_concurrency: @concurrency,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.reduce(0, fn
        {:ok, {:ok, {id, score, fp}}}, count ->
          case Nodes.set_ilv(id, score, fp) do
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
  # Drift detection for new claims
  # ---------------------------------------------------------------------------

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
    Map.new(fp, fn {k, v} -> {to_string(k), v} end)
  end

  defp broadcast(true, graph_id, message) do
    Phoenix.PubSub.broadcast(Xwa.PubSub, "graph:#{graph_id}", message)
  end

  defp broadcast(false, _graph_id, _message), do: :ok
end
