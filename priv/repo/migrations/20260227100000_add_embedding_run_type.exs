defmodule Xwa.Repo.Migrations.AddEmbeddingRunType do
  use Ecto.Migration

  def up do
    # Drop old constraint and recreate with 'embedding' included
    drop constraint(:extraction_runs, :valid_run_type)

    create constraint(:extraction_runs, :valid_run_type,
             check: "run_type IN ('claim', 'edge', 'embedding')"
           )
  end

  def down do
    drop constraint(:extraction_runs, :valid_run_type)

    create constraint(:extraction_runs, :valid_run_type,
             check: "run_type IN ('claim', 'edge')"
           )
  end
end
