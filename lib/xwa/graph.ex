defmodule Xwa.Graph do
  @moduledoc """
  Thin wrapper around Bolt.Sips for executing Cypher queries against Memgraph.

  All queries go through this module so that:
  - The connection pool is centralised in one place
  - We can swap the underlying driver (e.g. Neo4j) without touching call sites
  - Error handling and result shaping live in one place

  ## Usage

      # Simple query returning a list of result maps
      {:ok, rows} = Xwa.Graph.query("MATCH (n:Claim) RETURN n LIMIT 10")

      # Parameterised query
      {:ok, rows} = Xwa.Graph.query(
        "MATCH (n:Claim {id: $id}) RETURN n",
        %{id: "some-uuid"}
      )

      # Fire-and-forget write (returns :ok or {:error, reason})
      :ok = Xwa.Graph.run("CREATE (n:Claim {id: $id, text: $text})", %{id: "...", text: "..."})

      # Inside a transaction
      Xwa.Graph.transaction(fn conn ->
        Bolt.Sips.query!(conn, "CREATE (n:Claim {id: $id})", %{id: "1"})
        Bolt.Sips.query!(conn, "CREATE (n:Claim {id: $id})", %{id: "2"})
      end)
  """

  @doc """
  Executes a Cypher query and returns `{:ok, [map()]}` on success,
  or `{:error, reason}` on failure.

  Parameters should be passed as a map with atom or string keys.
  """
  @spec query(String.t(), map()) :: {:ok, [map()]} | {:error, any()}
  def query(cypher, params \\ %{}) do
    conn = Bolt.Sips.conn()

    case Bolt.Sips.query(conn, cypher, params) do
      {:ok, response} -> {:ok, response.results}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Like `query/2` but raises on error.
  """
  @spec query!(String.t(), map()) :: [map()]
  def query!(cypher, params \\ %{}) do
    conn = Bolt.Sips.conn()
    Bolt.Sips.query!(conn, cypher, params).results
  end

  @doc """
  Executes a Cypher write statement and returns `:ok` or `{:error, reason}`.
  Use this for CREATE / MERGE / SET / DELETE statements where you don't
  need to inspect the returned rows.
  """
  @spec run(String.t(), map()) :: :ok | {:error, any()}
  def run(cypher, params \\ %{}) do
    conn = Bolt.Sips.conn()

    case Bolt.Sips.query(conn, cypher, params) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Executes a function inside a Bolt transaction.
  The function receives the connection as its argument and should use
  `Bolt.Sips.query!/3` directly against it.

  Automatically commits on success and rolls back on exception.
  """
  @spec transaction((Bolt.Sips.conn() -> any())) :: {:ok, any()} | {:error, any()}
  def transaction(fun) when is_function(fun, 1) do
    conn = Bolt.Sips.conn()
    Bolt.Sips.transaction(conn, fun)
  end

  @doc """
  Returns a raw connection from the pool for advanced use cases.
  Prefer `query/2`, `run/2`, and `transaction/1` for normal usage.
  """
  @spec conn() :: Bolt.Sips.conn()
  def conn, do: Bolt.Sips.conn()
end
