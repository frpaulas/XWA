defmodule Xwa.Graph.Edges do
  @moduledoc """
  Context for managing RELATES edges between Claim nodes in the Memgraph
  knowledge graph.

  All edges are stored with the universal Cypher relationship type `:RELATES`.
  The emergent, domain-specific `type` field is stored as a property.

  ## Directionality

  Physically, all edges are stored from → to in Memgraph. For edges where
  `directed: false`, queries use the undirected pattern `(a)-[:RELATES]-(b)`
  so both traversal directions are considered.

  ## Graph tenancy

  Every edge carries a `graph_id` property scoping it to one Postgres Graph.
  List functions require a `graph_id`. Visibility rules mirror nodes:
  - "system"  — AI-extracted, visible to all graph members
  - "private" — only visible to `created_by` user
  - "shared"  — visible to members in `shared_with` (or all if empty)

  ## Edge identity

  Like nodes, edges carry their own `id` UUID property for stable external
  referencing. Memgraph's internal element id is not used.
  """

  alias Xwa.Graph
  alias Xwa.Graph.Edge

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Gets a single edge by its UUID.
  Returns `{:ok, edge}` or `{:ok, nil}` if not found.
  """
  @spec get(String.t()) :: {:ok, Edge.t() | nil} | {:error, any()}
  def get(id) when is_binary(id) do
    cypher = "MATCH ()-[r:RELATES {id: $id}]->() RETURN r"

    case Graph.query(cypher, %{id: id}) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row | _]} -> {:ok, edge_from_row(row)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Like `get/1` but raises if not found or on error.
  """
  @spec get!(String.t()) :: Edge.t()
  def get!(id) when is_binary(id) do
    case get(id) do
      {:ok, nil} -> raise "Edge not found: #{id}"
      {:ok, edge} -> edge
      {:error, reason} -> raise "Graph query failed: #{inspect(reason)}"
    end
  end

  @doc """
  Returns all visible edges in one or more graphs for the given user.

  `graph_id` may be a single binary UUID or a list of UUIDs (for composite
  graphs resolved via `Xwa.Graphs.resolve_graph_ids/1`).

  Visibility rules:
  - "system" edges are visible to all members
  - "private" edges are only visible to their creator
  - "shared" edges are visible to all (empty shared_with) or listed users
  - Additionally filters out edges where user_id is in hidden_by
  """
  @spec list(String.t() | [String.t()], String.t()) :: {:ok, [Edge.t()]} | {:error, any()}
  def list(graph_id, user_id) when is_binary(graph_id) and is_binary(user_id) do
    list([graph_id], user_id)
  end

  def list(graph_ids, user_id) when is_list(graph_ids) and is_binary(user_id) do
    cypher = """
    MATCH ()-[r:RELATES]->()
    WHERE r.graph_id IN $graph_ids
      AND (r.visibility = 'system'
        OR r.created_by = $user_id
        OR (r.visibility = 'shared' AND (size(coalesce(r.shared_with, [])) = 0 OR $user_id IN coalesce(r.shared_with, []))))
      AND NOT $user_id IN coalesce(r.hidden_by, [])
    RETURN r
    """

    case Graph.query(cypher, %{graph_ids: graph_ids, user_id: user_id}) do
      {:ok, rows} -> {:ok, Enum.map(rows, &edge_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all edges leaving or arriving at a given node, respecting visibility.

  ## Options
    - `:direction` — `:out` (default), `:in`, or `:both`
    - `:type` — filter by emergent type string
    - `:user_id` — required for visibility filtering
  """
  @spec list_for_node(String.t(), keyword()) :: {:ok, [Edge.t()]} | {:error, any()}
  def list_for_node(node_id, opts \\ []) when is_binary(node_id) do
    direction = Keyword.get(opts, :direction, :out)
    type_filter = Keyword.get(opts, :type)
    user_id = Keyword.get(opts, :user_id)

    match_pattern =
      case direction do
        :in -> "(other:Claim)-[r:RELATES]->(n:Claim {id: $node_id})"
        :both -> "(n:Claim {id: $node_id})-[r:RELATES]-(other:Claim)"
        _ -> "(n:Claim {id: $node_id})-[r:RELATES]->(other:Claim)"
      end

    type_clause = if type_filter, do: "AND r.type = $type", else: ""

    visibility_clause =
      if user_id do
        """
        AND (r.visibility = 'system'
          OR r.created_by = $user_id
          OR (r.visibility = 'shared' AND (size(coalesce(r.shared_with, [])) = 0 OR $user_id IN coalesce(r.shared_with, []))))
        AND NOT $user_id IN coalesce(r.hidden_by, [])
        """
      else
        ""
      end

    cypher = """
    MATCH #{match_pattern}
    WHERE 1=1
    #{type_clause}
    #{visibility_clause}
    RETURN r
    """

    params =
      %{node_id: node_id}
      |> then(fn p -> if type_filter, do: Map.put(p, :type, type_filter), else: p end)
      |> then(fn p -> if user_id, do: Map.put(p, :user_id, user_id), else: p end)

    case Graph.query(cypher, params) do
      {:ok, rows} -> {:ok, Enum.map(rows, &edge_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all edges between two specific nodes, in either direction.
  """
  @spec list_between(String.t(), String.t()) :: {:ok, [Edge.t()]} | {:error, any()}
  def list_between(from_id, to_id) when is_binary(from_id) and is_binary(to_id) do
    cypher = """
    MATCH (a:Claim {id: $from_id})-[r:RELATES]-(b:Claim {id: $to_id})
    RETURN r
    """

    case Graph.query(cypher, %{from_id: from_id, to_id: to_id}) do
      {:ok, rows} -> {:ok, Enum.map(rows, &edge_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all edges of a given emergent type within a graph.
  """
  @spec list_by_type(String.t(), String.t()) :: {:ok, [Edge.t()]} | {:error, any()}
  def list_by_type(graph_id, type) when is_binary(graph_id) and is_binary(type) do
    cypher = """
    MATCH ()-[r:RELATES {graph_id: $graph_id, type: $type}]->()
    RETURN r
    """

    case Graph.query(cypher, %{graph_id: graph_id, type: type}) do
      {:ok, rows} -> {:ok, Enum.map(rows, &edge_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all edges referencing a given source document UUID.
  """
  @spec list_by_document(String.t()) :: {:ok, [Edge.t()]} | {:error, any()}
  def list_by_document(document_id) when is_binary(document_id) do
    cypher = """
    MATCH ()-[r:RELATES]->()
    WHERE $document_id IN r.source_document_ids
    RETURN r
    """

    case Graph.query(cypher, %{document_id: document_id}) do
      {:ok, rows} -> {:ok, Enum.map(rows, &edge_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all contested edges in a graph.
  """
  @spec list_contested(String.t()) :: {:ok, [Edge.t()]} | {:error, any()}
  def list_contested(graph_id) when is_binary(graph_id) do
    cypher = """
    MATCH ()-[r:RELATES {graph_id: $graph_id, contested: true}]->()
    RETURN r
    """

    case Graph.query(cypher, %{graph_id: graph_id}) do
      {:ok, rows} -> {:ok, Enum.map(rows, &edge_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all edges in a graph awaiting human validation.
  """
  @spec list_unvalidated(String.t()) :: {:ok, [Edge.t()]} | {:error, any()}
  def list_unvalidated(graph_id) when is_binary(graph_id) do
    cypher = """
    MATCH ()-[r:RELATES {graph_id: $graph_id}]->()
    WHERE r.human_validated = false
    RETURN r
    ORDER BY r.confidence ASC
    """

    case Graph.query(cypher, %{graph_id: graph_id}) do
      {:ok, rows} -> {:ok, Enum.map(rows, &edge_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all distinct emergent edge type strings in a graph.
  """
  @spec list_types(String.t()) :: {:ok, [String.t()]} | {:error, any()}
  def list_types(graph_id) when is_binary(graph_id) do
    cypher = """
    MATCH ()-[r:RELATES {graph_id: $graph_id}]->()
    RETURN DISTINCT r.type AS type
    ORDER BY type ASC
    """

    case Graph.query(cypher, %{graph_id: graph_id}) do
      {:ok, rows} -> {:ok, Enum.map(rows, & &1["type"])}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Mutations
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new RELATES edge between two Claim nodes.

  Accepts either an `Xwa.Graph.Edge` struct (already validated) or a plain
  map of attributes which will be passed through `Edge.new/1`.

  The Claim nodes identified by `from_node_id` and `to_node_id` must
  already exist in the graph. Returns `{:error, :nodes_not_found}` if
  either is missing.
  """
  @spec create(Edge.t() | map()) :: {:ok, Edge.t()} | {:error, any()}
  def create(%Edge{} = edge) do
    params = Edge.to_params(edge)

    cypher = """
    MATCH (from:Claim {id: $from_node_id})
    MATCH (to:Claim {id: $to_node_id})
    CREATE (from)-[r:RELATES]->(to)
    SET r = $props
    RETURN r
    """

    case Graph.query(cypher, %{
           from_node_id: edge.from_node_id,
           to_node_id: edge.to_node_id,
           props: params
         }) do
      {:ok, [row | _]} -> {:ok, edge_from_row(row)}
      {:ok, []} -> {:error, :nodes_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def create(attrs) when is_map(attrs) do
    case Edge.new(attrs) do
      {:ok, edge} -> create(edge)
      {:error, reasons} -> {:error, {:validation, reasons}}
    end
  end

  @doc """
  Updates mutable fields on an existing edge.

  Allowed fields: `type`, `label`, `directed`, `importance`, `certainty`,
  `confidence`, `human_validated`, `contested`, `source_document_ids`,
  `visibility`, `notes`.
  """
  @spec update(String.t(), map()) :: {:ok, Edge.t()} | {:error, any()}
  def update(id, attrs) when is_binary(id) and is_map(attrs) do
    allowed = ~w(
      type label directed importance certainty
      confidence human_validated contested
      source_document_ids visibility notes
    )a

    updates =
      attrs
      |> Map.take(allowed)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.into(%{})

    if map_size(updates) == 0 do
      get(id)
    else
      set_clauses =
        updates
        |> Map.keys()
        |> Enum.map_join(", ", fn k -> "r.#{k} = $#{k}" end)

      cypher = """
      MATCH ()-[r:RELATES {id: $id}]->()
      SET #{set_clauses}
      RETURN r
      """

      params = Map.put(updates, :id, id)

      case Graph.query(cypher, params) do
        {:ok, [row | _]} -> {:ok, edge_from_row(row)}
        {:ok, []} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Adds a user UUID to the `validated_by` list and sets `human_validated`
  to true. Idempotent.
  """
  @spec validate_edge(String.t(), String.t()) :: {:ok, Edge.t()} | {:error, any()}
  def validate_edge(edge_id, user_id) when is_binary(edge_id) and is_binary(user_id) do
    cypher = """
    MATCH ()-[r:RELATES {id: $edge_id}]->()
    SET r.human_validated = true,
        r.validated_by = CASE
          WHEN $user_id IN coalesce(r.validated_by, [])
          THEN r.validated_by
          ELSE coalesce(r.validated_by, []) + [$user_id]
        END
    RETURN r
    """

    case Graph.query(cypher, %{edge_id: edge_id, user_id: user_id}) do
      {:ok, [row | _]} -> {:ok, edge_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Flags or unflags an edge as contested.
  """
  @spec set_contested(String.t(), boolean()) :: :ok | {:error, any()}
  def set_contested(id, contested) when is_binary(id) and is_boolean(contested) do
    Graph.run(
      "MATCH ()-[r:RELATES {id: $id}]->() SET r.contested = $contested",
      %{id: id, contested: contested}
    )
  end

  @doc """
  Adds a source document UUID to an edge's `source_document_ids` list. Idempotent.
  """
  @spec add_source_document(String.t(), String.t()) :: :ok | {:error, any()}
  def add_source_document(edge_id, document_id)
      when is_binary(edge_id) and is_binary(document_id) do
    cypher = """
    MATCH ()-[r:RELATES {id: $edge_id}]->()
    SET r.source_document_ids = CASE
      WHEN $document_id IN coalesce(r.source_document_ids, [])
      THEN r.source_document_ids
      ELSE coalesce(r.source_document_ids, []) + [$document_id]
    END
    """

    Graph.run(cypher, %{edge_id: edge_id, document_id: document_id})
  end

  @doc """
  Hides an edge for a specific user by appending their UUID to the
  `hidden_by` list. Idempotent.
  """
  @spec hide_for(String.t(), String.t()) :: :ok | {:error, any()}
  def hide_for(edge_id, user_id) when is_binary(edge_id) and is_binary(user_id) do
    cypher = """
    MATCH ()-[r:RELATES {id: $edge_id}]->()
    SET r.hidden_by = CASE
      WHEN $user_id IN coalesce(r.hidden_by, [])
      THEN r.hidden_by
      ELSE coalesce(r.hidden_by, []) + [$user_id]
    END
    """

    Graph.run(cypher, %{edge_id: edge_id, user_id: user_id})
  end

  @doc """
  Deletes an edge by its UUID.
  """
  @spec delete(String.t()) :: :ok | {:error, any()}
  def delete(id) when is_binary(id) do
    Graph.run("MATCH ()-[r:RELATES {id: $id}]->() DELETE r", %{id: id})
  end

  @doc false
  def from_bolt(bolt_rel), do: Edge.from_bolt(bolt_rel)

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp edge_from_row(%{"r" => bolt_rel}), do: Edge.from_bolt(bolt_rel)
  defp edge_from_row(row) when is_map(row), do: Edge.from_bolt(row)
end
