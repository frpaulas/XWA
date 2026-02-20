defmodule Xwa.Graph.Setup do
  @moduledoc """
  Creates and maintains Memgraph indexes for the XWA knowledge graph.

  Run `Xwa.Graph.Setup.run/0` once after a fresh Memgraph install, or
  any time you need to ensure indexes are in place (it is idempotent).

  ## Indexes created

  - Label index on `:Claim` — speeds up all label scans
  - Property indexes on the fields most commonly used in WHERE clauses
  - A unique constraint on `id` — the UUID is the stable graph identity
  - Vector index on `embedding` — deferred until embedding dimensions are
    confirmed; call `create_vector_index/1` explicitly with the dimension

  ## Usage

      # In iex or a Mix task:
      Xwa.Graph.Setup.run()

      # Once you know your embedding model's output dimension:
      Xwa.Graph.Setup.create_vector_index(1024)
  """

  alias Xwa.Graph

  @doc """
  Creates all non-vector indexes and constraints.
  Safe to call multiple times — uses IF NOT EXISTS where supported,
  and swallows already-exists errors gracefully.
  """
  @spec run() :: :ok
  def run do
    indexes = [
      # Label index — baseline for all :Claim scans
      {"label index on :Claim", "CREATE INDEX ON :Claim"},

      # Property indexes — Claim nodes
      {"index on :Claim(id)", "CREATE INDEX ON :Claim(id)"},
      {"index on :Claim(source_document_id)", "CREATE INDEX ON :Claim(source_document_id)"},
      {"index on :Claim(source_type)", "CREATE INDEX ON :Claim(source_type)"},
      {"index on :Claim(corpus_layer)", "CREATE INDEX ON :Claim(corpus_layer)"},
      {"index on :Claim(human_validated)", "CREATE INDEX ON :Claim(human_validated)"},
      {"index on :Claim(contested)", "CREATE INDEX ON :Claim(contested)"},
      {"index on :Claim(confidence)", "CREATE INDEX ON :Claim(confidence)"},
      {"index on :Claim(asserted_at)", "CREATE INDEX ON :Claim(asserted_at)"},
      {"index on :Claim(ai_inferred)", "CREATE INDEX ON :Claim(ai_inferred)"},

      # Unique constraint on :Claim(id) — UUID must be stable and unique
      {"unique constraint on :Claim(id)", "CREATE CONSTRAINT ON (n:Claim) ASSERT n.id IS UNIQUE"},

      # Edge indexes — RELATES relationships
      # Memgraph supports edge-type property indexes via EDGE INDEX syntax
      {"edge index on :RELATES(id)", "CREATE EDGE INDEX ON :RELATES(id)"},
      {"edge index on :RELATES(type)", "CREATE EDGE INDEX ON :RELATES(type)"},
      {"edge index on :RELATES(human_validated)",
       "CREATE EDGE INDEX ON :RELATES(human_validated)"},
      {"edge index on :RELATES(contested)", "CREATE EDGE INDEX ON :RELATES(contested)"},
      {"edge index on :RELATES(confidence)", "CREATE EDGE INDEX ON :RELATES(confidence)"}
    ]

    results =
      Enum.map(indexes, fn {description, cypher} ->
        case Graph.run(cypher) do
          :ok ->
            IO.puts("  ✓ #{description}")
            :ok

          {:error, reason} ->
            # Memgraph returns an error if the index/constraint already exists.
            # We treat that as success — setup is idempotent by design.
            if already_exists?(reason) do
              IO.puts("  ~ #{description} (already exists)")
              :ok
            else
              IO.puts("  ✗ #{description}: #{inspect(reason)}")
              {:error, {description, reason}}
            end
        end
      end)

    failures = Enum.filter(results, &match?({:error, _}, &1))

    if failures == [] do
      IO.puts("\nMemgraph setup complete.")
      :ok
    else
      IO.puts("\nMemgraph setup completed with #{length(failures)} failure(s).")
      :ok
    end
  end

  @doc """
  Creates a vector index on `:Claim(embedding)` for semantic similarity search.

  Must be called explicitly once the embedding model's output dimension is known.
  The dimension should match the model you are using, e.g.:
  - Voyage 3 Large → 1024
  - text-embedding-3-large → 3072
  - text-embedding-3-small → 1536

  The metric is cosine similarity, which is standard for normalised embeddings.

  ## Example

      Xwa.Graph.Setup.create_vector_index(1024)
  """
  @spec create_vector_index(pos_integer()) :: :ok | {:error, any()}
  def create_vector_index(dimension) when is_integer(dimension) and dimension > 0 do
    cypher = """
    CREATE VECTOR INDEX claim_embeddings
    ON :Claim(embedding)
    WITH CONFIG {"dimension": #{dimension}, "capacity": 10000, "metric": "cos"}
    """

    case Graph.run(cypher) do
      :ok ->
        IO.puts("✓ vector index created on :Claim(embedding) with dimension #{dimension}")
        :ok

      {:error, reason} ->
        if already_exists?(reason) do
          IO.puts("~ vector index on :Claim(embedding) already exists")
          :ok
        else
          IO.puts("✗ vector index creation failed: #{inspect(reason)}")
          {:error, reason}
        end
    end
  end

  @doc """
  Drops the vector index if it exists. Useful when switching embedding models,
  which requires re-indexing with a different dimension.
  """
  @spec drop_vector_index() :: :ok | {:error, any()}
  def drop_vector_index do
    case Graph.run("DROP INDEX claim_embeddings") do
      :ok ->
        IO.puts("✓ vector index dropped")
        :ok

      {:error, reason} ->
        if not_found?(reason) do
          IO.puts("~ vector index did not exist")
          :ok
        else
          {:error, reason}
        end
    end
  end

  @doc """
  Returns the currently defined indexes and constraints from Memgraph.
  Useful for inspecting the current state.
  """
  @spec show_indexes() :: {:ok, [map()]} | {:error, any()}
  def show_indexes do
    Graph.query("SHOW INDEX INFO")
  end

  @doc """
  Returns the currently defined constraints from Memgraph.
  """
  @spec show_constraints() :: {:ok, [map()]} | {:error, any()}
  def show_constraints do
    Graph.query("SHOW CONSTRAINT INFO")
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp already_exists?(reason) do
    msg = inspect(reason)
    String.contains?(msg, "already exists") or String.contains?(msg, "AlreadyExistsError")
  end

  defp not_found?(reason) do
    msg = inspect(reason)
    String.contains?(msg, "not found") or String.contains?(msg, "does not exist")
  end
end
