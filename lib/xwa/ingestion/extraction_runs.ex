defmodule Xwa.Ingestion.ExtractionRuns do
  @moduledoc """
  Context for logging and querying AI extraction run records.

  Each call to the Claude API during ingestion creates one ExtractionRun
  record capturing cost, timing, model, prompt version, and results.
  """

  import Ecto.Query
  alias Xwa.Repo
  alias Xwa.Ingestion.ExtractionRun

  # ---------------------------------------------------------------------------
  # Logging
  # ---------------------------------------------------------------------------

  @doc """
  Records a completed extraction run.

  `attrs` should include at minimum:
  - `:run_type`   — "claim" or "edge"
  - `:model`      — model identifier string
  - `:status`     — "ok", "error", or "partial"

  Plus any subset of the cost/timing/result fields.
  Returns `{:ok, run}` or `{:error, changeset}`.
  """
  @spec log(map()) :: {:ok, ExtractionRun.t()} | {:error, Ecto.Changeset.t()}
  def log(attrs) when is_map(attrs) do
    %ExtractionRun{}
    |> ExtractionRun.changeset(attrs)
    |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns all extraction runs for a given document, most recent first.
  """
  @spec list_for_document(String.t()) :: [ExtractionRun.t()]
  def list_for_document(document_id) do
    Repo.all(
      from r in ExtractionRun,
        where: r.document_id == ^document_id,
        order_by: [desc: r.inserted_at]
    )
  end

  @doc """
  Returns all extraction runs for a given graph, most recent first.
  """
  @spec list_for_graph(String.t()) :: [ExtractionRun.t()]
  def list_for_graph(graph_id) do
    Repo.all(
      from r in ExtractionRun,
        where: r.graph_id == ^graph_id,
        order_by: [desc: r.inserted_at]
    )
  end

  @doc """
  Returns aggregate cost stats for a graph: total input tokens, output tokens,
  and USD cost across all runs.
  """
  @spec cost_summary_for_graph(String.t()) :: %{
          input_tokens: integer(),
          output_tokens: integer(),
          cost_usd: Decimal.t(),
          run_count: integer()
        }
  def cost_summary_for_graph(graph_id) do
    result =
      Repo.one(
        from r in ExtractionRun,
          where: r.graph_id == ^graph_id,
          select: %{
            input_tokens: sum(r.input_tokens),
            output_tokens: sum(r.output_tokens),
            cost_usd: sum(r.cost_usd),
            run_count: count(r.id)
          }
      )

    %{
      input_tokens: result.input_tokens || 0,
      output_tokens: result.output_tokens || 0,
      cost_usd: result.cost_usd || Decimal.new(0),
      run_count: result.run_count || 0
    }
  end

  @doc """
  Returns per-month cost totals for the last 12 complete months plus the current
  month-to-date, ordered oldest-first. Each row is a map:

    %{month: "2026-02", runs: 42, input_tokens: 1_200_000,
      output_tokens: 80_000, cost_usd: Decimal}
  """
  @spec monthly_cost_summary() :: [map()]
  def monthly_cost_summary do
    cutoff = Date.utc_today() |> Date.beginning_of_month() |> Date.add(-365)
    cutoff_dt = DateTime.new!(cutoff, ~T[00:00:00], "Etc/UTC")

    Repo.all(
      from r in ExtractionRun,
        where: r.inserted_at >= ^cutoff_dt,
        group_by: fragment("to_char(?, 'YYYY-MM')", r.inserted_at),
        order_by: fragment("to_char(?, 'YYYY-MM')", r.inserted_at),
        select: %{
          month: fragment("to_char(?, 'YYYY-MM')", r.inserted_at),
          runs: count(r.id),
          input_tokens: sum(r.input_tokens),
          output_tokens: sum(r.output_tokens),
          cost_usd: sum(r.cost_usd)
        }
    )
  end

  @doc """
  Returns all failed runs for a graph.
  """
  @spec list_errors_for_graph(String.t()) :: [ExtractionRun.t()]
  def list_errors_for_graph(graph_id) do
    Repo.all(
      from r in ExtractionRun,
        where: r.graph_id == ^graph_id and r.status == "error",
        order_by: [desc: r.inserted_at]
    )
  end
end
