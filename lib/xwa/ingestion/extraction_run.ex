defmodule Xwa.Ingestion.ExtractionRun do
  use Ecto.Schema
  import Ecto.Changeset

  @run_types ~w(claim edge)
  @statuses ~w(ok error partial)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "extraction_runs" do
    belongs_to :document, Xwa.Documents.Document
    belongs_to :graph, Xwa.Graphs.Graph

    field :run_type, :string
    field :model, :string
    field :prompt_version, :string
    field :status, :string, default: "ok"

    # Input volume
    field :document_size_bytes, :integer
    field :chunk_index, :integer
    field :total_chunks, :integer

    # Results
    field :nodes_extracted, :integer
    field :edges_extracted, :integer
    field :nodes_deduplicated, :integer

    # Cost
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cost_usd, :decimal

    # Timing
    field :latency_ms, :integer
    field :duration_ms, :integer

    # API metadata
    field :finish_reason, :string
    field :retries, :integer, default: 0

    # Error
    field :error_message, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :document_id,
      :graph_id,
      :run_type,
      :model,
      :prompt_version,
      :status,
      :document_size_bytes,
      :chunk_index,
      :total_chunks,
      :nodes_extracted,
      :edges_extracted,
      :nodes_deduplicated,
      :input_tokens,
      :output_tokens,
      :cost_usd,
      :latency_ms,
      :duration_ms,
      :finish_reason,
      :retries,
      :error_message
    ])
    |> validate_required([:run_type, :model, :status])
    |> validate_inclusion(:run_type, @run_types)
    |> validate_inclusion(:status, @statuses)
  end
end
