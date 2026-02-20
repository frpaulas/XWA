defmodule Xwa.Repo.Migrations.CreateExtractionRuns do
  use Ecto.Migration

  def change do
    create table(:extraction_runs, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :document_id,
          references(:documents, type: :uuid, on_delete: :nilify_all),
          null: true

      add :graph_id,
          references(:graphs, type: :uuid, on_delete: :nilify_all),
          null: true

      # What kind of extraction was this?
      add :run_type, :string, null: false
      # ^ "claim" | "edge"

      # Which model and prompt were used?
      add :model, :string, null: false
      add :prompt_version, :string

      # Outcome
      add :status, :string, null: false, default: "ok"
      # ^ "ok" | "error" | "partial"

      # Input volume
      add :document_size_bytes, :integer
      add :chunk_index, :integer
      add :total_chunks, :integer

      # Results (nullable — claim runs don't have edges_extracted, etc.)
      add :nodes_extracted, :integer
      add :edges_extracted, :integer
      add :nodes_deduplicated, :integer

      # Cost
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :cost_usd, :decimal, precision: 10, scale: 6

      # Timing
      add :latency_ms, :integer
      add :duration_ms, :integer

      # API metadata
      add :finish_reason, :string
      add :retries, :integer, null: false, default: 0

      # Error detail
      add :error_message, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:extraction_runs, [:document_id])
    create index(:extraction_runs, [:graph_id])
    create index(:extraction_runs, [:run_type])
    create index(:extraction_runs, [:status])
    create index(:extraction_runs, [:inserted_at])

    create constraint(:extraction_runs, :valid_run_type,
             check: "run_type IN ('claim', 'edge')"
           )

    create constraint(:extraction_runs, :valid_status,
             check: "status IN ('ok', 'error', 'partial')"
           )
  end
end
