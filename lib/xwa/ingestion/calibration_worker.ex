defmodule Xwa.Ingestion.CalibrationWorker do
  @moduledoc """
  Background task runner for ILV corpus calibration.

  Uses Task.Supervisor (same pattern as IngestionWorker).
  Broadcasts progress via PubSub on `"graph:\#{graph_id}"`.

  ## Message types broadcast during calibration

      {:calibration_progress, :started, %{total: integer}}
      {:calibration_progress, :phase1, %{done: integer, total: integer}}
      {:calibration_progress, :phase2_start, %{gfp: map, iterations: integer}}
      {:calibration_progress, :phase2, %{done: integer, total: integer}}
      {:calibration_complete, %{gfp: map, scored: integer, iterations: integer}}
      {:calibration_failed, reason}
  """

  require Logger

  alias Xwa.Graph.Calibrator

  @doc "Runs calibration in a supervised background task."
  def run_async(graph_id) do
    Task.Supervisor.start_child(
      Xwa.TaskSupervisor,
      fn -> run(graph_id) end
    )
  end

  @doc "Runs calibration synchronously. Returns `:ok` or `:error`."
  def run(graph_id) do
    Logger.info("[CalibrationWorker] Starting calibration for graph #{graph_id}")

    case Calibrator.calibrate(graph_id) do
      {:ok, %{gfp: gfp, scored: n, iterations: iters}} ->
        Logger.info(
          "[CalibrationWorker] Complete: #{n} claims scored, #{iters} iteration(s), GFP=#{inspect(gfp)}"
        )
        :ok

      {:error, reason} ->
        Logger.error("[CalibrationWorker] Failed: #{inspect(reason)}")
        :error
    end
  end
end
