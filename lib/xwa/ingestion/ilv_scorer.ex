defmodule Xwa.Ingestion.IlvScorer do
  @moduledoc """
  Client for the ILV credibility scoring API.

  Returns a score (0–1) and a 4-dimensional fingerprint for each text,
  normalized against a corpus fingerprint (GFP).

  ## Fingerprint math

  The API's normalization is linear:

      FP(text, GFP)[d] = raw[d] - GFP[d] + 0.5

  Equivalently, `raw[d] = FP[d] + GFP[d] - 0.5`.

  When initial GFP = `{0.5, 0.5, 0.5, 0.5}`, the returned FP equals the raw FP.
  This lets the calibrator run Phase 1 once (N calls) and then converge GFP via
  pure math before running Phase 2 (N calls) for final normalized scores.
  """

  require Logger

  @api_url "https://ilv-api.fly.dev/api/v1/score"
  @initial_gfp %{w: 0.5, x: 0.5, y: 0.5, z: 0.5}
  @convergence_threshold 0.01

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Scores a single text against an optional corpus fingerprint.

  Returns `{:ok, %{score: float, fingerprint: %{w: float, x: float, y: float, z: float}}}`
  or `{:error, reason}`.
  """
  @spec score(String.t(), map() | nil) :: {:ok, %{score: float(), fingerprint: map()}} | {:error, any()}
  def score(text, corpus_fingerprint \\ nil) do
    body =
      if corpus_fingerprint,
        do: %{text: text, corpus_fingerprint: corpus_fingerprint},
        else: %{text: text}

    case Req.post(@api_url, json: body, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: data}} ->
        {:ok, %{score: data["score"], fingerprint: atomize_fp(data["fingerprint"])}}

      {:ok, %{status: status, body: %{"detail" => detail}}} ->
        {:error, "HTTP #{status}: #{detail}"}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("[IlvScorer] Unexpected response #{status}: #{inspect(body)}")
        {:error, "HTTP #{status}: #{inspect(body)}"}

      {:error, reason} ->
        Logger.warning("[IlvScorer] HTTP error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Returns the initial GFP used to bootstrap calibration: {0.5, 0.5, 0.5, 0.5}."
  def initial_gfp, do: @initial_gfp

  @doc "Returns the convergence threshold (max per-dimension delta to consider GFP stable)."
  def convergence_threshold, do: @convergence_threshold

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # API returns string-keyed fingerprint maps; normalize to atom keys.
  defp atomize_fp(%{"w" => w, "x" => x, "y" => y, "z" => z}), do: %{w: w, x: x, y: y, z: z}
  defp atomize_fp(fp) when is_map(fp), do: fp
  defp atomize_fp(_), do: @initial_gfp
end
