defmodule Xwa.Graph.Edges do
  @moduledoc """
  Context for managing RELATES edges between Claim nodes in the Memgraph
  knowledge graph.

  All edges are stored with the universal Cypher relationship type `:RELATES`.
  The emergent, domain-specific `type` field is stored as a property.

  ## Directionality

  Physically, all edges are stored from → to in Memgraph. For edges where
  `directed: false`, queries use the undirected pattern `(a)-[:RELATES]-(b)`
  so both traversal directions are considered. The `directed` flag on the
  returned struct tells callers how to interpret the relationship.

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
  Returns all edges leaving or arriving at a given node.

  For directed edges, only outgoing edges from the node are returned
  unless `direction: :in` or `direction: :both` is specified.
  For undirected edges (directed: false), both directions are always
  returned regardless of the option.

  ## Options

    - `:direction` — `:out` (default), `:in`, or `:both`
    - `:type` — filter by emergent type string
  """
  @spec list_for_node(String.t(), keyword()) :: {:ok, [Edge.t()]} | {:error, any()}
  def list_for_node(node_id, opts \\ []) when is_binary(node_id) do
    direction = Keyword.get(opts, :direction, :out)
    type_filter = Keyword.get(opts, :type)

    {match_pattern, return_clause} =
      case direction do
        :in -> {"(other:Claim)-[r:RELATES]->(n:Claim {id: $node_id})", "r"}
        :both -> {"(n:Claim {id: $node_id})-[r:RELATES]-(other:Claim)", "r"}
        _ -> {"(n:Claim {id: $node_id})-[r:RELATES]->(other:Claim)", "r"}
      end

    {where_clause, params} =
      if type_filter do
        {"WHERE r.type = $type", %{node_id: node_id, type: type_filter}}
      else
        {"", %{node_id: node_id}}
      end

    cypher = """
    MATCH #{match_pattern}
    #{where_clause}
    RETURN #{return_clause}
    """

    case Graph.query(cypher, params) do
      {:ok, rows} -> {:ok, Enum.map(rows, &edge_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all edges between two specific nodes, in either direction.
  Useful for checking whether a relationship already exists before creating one.
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
  Returns all edges of a given emergent type across the whole graph.
  Use with care on large graphs.
  """
  @spec list_by_type(String.t()) :: {:ok, [Edge.t()]} | {:error, any()}
  def list_by_type(type) when is_binary(type) do
    cypher = """
    MATCH ()-[r:RELATES {type: $type}]->()
    RETURN r
    """

    case Graph.query(cypher, %{type: type}) do
      {:ok, rows} -> {:ok, Enum.map(rows, &edge_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all edges referencing a given source document UUID.
  Useful for reviewing everything extracted from a single document.
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
  Returns all contested edges.
  """
  @spec list_contested() :: {:ok, [Edge.t()]} | {:error, any()}
  def list_contested do
    case Graph.query("MATCH ()-[r:RELATES {contested: true}]->() RETURN r") do
      {:ok, rows} -> {:ok, Enum.map(rows, &edge_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all edges awaiting human validation.
  """
  @spec list_unvalidated() :: {:ok, [Edge.t()]} | {:error, any()}
  def list_unvalidated do
    cypher = """
    MATCH ()-[r:RELATES]->()
    WHERE r.human_validated = false
    RETURN r
    ORDER BY r.confidence ASC
    """

    case Graph.query(cypher) do
      {:ok, rows} -> {:ok, Enum.map(rows, &edge_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all distinct emergent edge type strings currently in the graph.
  Useful for exploring the accumulated ontology vocabulary.
  """
  @spec list_types() :: {:ok, [String.t()]} | {:error, any()}
  def list_types do
    cypher = """
    MATCH ()-[r:RELATES]->()
    RETURN DISTINCT r.type AS type
    ORDER BY type ASC
    """

    case Graph.query(cypher) do
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

  Only the fields present in `attrs` are changed. `id`, `from_node_id`,
  and `to_node_id` are never updated — they are the stable identity of
  the edge.

  Allowed fields: `type`, `label`, `directed`, `importance`, `certainty`,
  `confidence`, `human_validated`, `contested`, `source_document_ids`, `notes`.
  """
  @spec update(String.t(), map()) :: {:ok, Edge.t()} | {:error, any()}
  def update(id, attrs) when is_binary(id) and is_map(attrs) do
    allowed = ~w(
      type label directed importance certainty
      confidence human_validated contested
      source_document_ids notes
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
  to true. Idempotent — adding the same validator twice has no effect.
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
  Adds a source document UUID to an edge's `source_document_ids` list.
  Idempotent — adding the same document twice has no effect.

  Used when a relationship is subsequently evidenced by an additional
  document — more sources strengthen confidence.
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
  `hidden_by` list. The edge remains in the graph for all other users.
  Idempotent — adding the same user twice has no effect.
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

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp edge_from_row(%{"r" => bolt_rel}), do: Edge.from_bolt(bolt_rel)
  defp edge_from_row(row) when is_map(row), do: Edge.from_bolt(row)
end
