defmodule Xwa.Graph.Nodes do
  @moduledoc """
  Context for managing Claim nodes in the Memgraph knowledge graph.

  All persistence goes through `Xwa.Graph` (the Bolt.Sips wrapper).
  This module owns the Cypher queries and maps results to and from
  `Xwa.Graph.Node` structs.

  ## Node identity

  Nodes are identified by the `id` property (a UUID string), not
  Memgraph's internal element id. All lookups use `id` so that the
  graph can be backed up, restored, or migrated without losing
  referential integrity.

  ## Embeddings

  The `embedding` field is populated separately by the AI pipeline.
  Use `set_embedding/2` once the vector has been computed. A vector
  index over `:Claim(embedding)` should be created via
  `Xwa.Graph.Setup.run/0` before semantic queries are issued.
  """

  alias Xwa.Graph
  alias Xwa.Graph.Node

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns all Claim nodes. Use with care on large graphs — prefer
  filtered queries in production.
  """
  @spec list() :: {:ok, [Node.t()]} | {:error, any()}
  def list do
    case Graph.query("MATCH (n:Claim) RETURN n") do
      {:ok, rows} -> {:ok, Enum.map(rows, &node_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Finds a Claim node by its UUID.
  Returns `{:ok, node}` or `{:ok, nil}` if not found.
  """
  @spec get(String.t()) :: {:ok, Node.t() | nil} | {:error, any()}
  def get(id) when is_binary(id) do
    case Graph.query("MATCH (n:Claim {id: $id}) RETURN n", %{id: id}) do
      {:ok, []} -> {:ok, nil}
      {:ok, [row | _]} -> {:ok, node_from_row(row)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Like `get/1` but raises if not found or on error.
  """
  @spec get!(String.t()) :: Node.t()
  def get!(id) when is_binary(id) do
    case get(id) do
      {:ok, nil} -> raise "Claim node not found: #{id}"
      {:ok, node} -> node
      {:error, reason} -> raise "Graph query failed: #{inspect(reason)}"
    end
  end

  @doc """
  Returns all Claim nodes referencing a given source document UUID.
  """
  @spec list_by_document(String.t()) :: {:ok, [Node.t()]} | {:error, any()}
  def list_by_document(document_id) when is_binary(document_id) do
    cypher = """
    MATCH (n:Claim {source_document_id: $document_id})
    RETURN n
    ORDER BY n.asserted_at ASC
    """

    case Graph.query(cypher, %{document_id: document_id}) do
      {:ok, rows} -> {:ok, Enum.map(rows, &node_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all Claim nodes with a given corpus_layer value.
  """
  @spec list_by_corpus_layer(String.t()) :: {:ok, [Node.t()]} | {:error, any()}
  def list_by_corpus_layer(layer) when is_binary(layer) do
    case Graph.query("MATCH (n:Claim {corpus_layer: $layer}) RETURN n", %{layer: layer}) do
      {:ok, rows} -> {:ok, Enum.map(rows, &node_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all Claim nodes awaiting human validation.
  """
  @spec list_unvalidated() :: {:ok, [Node.t()]} | {:error, any()}
  def list_unvalidated do
    cypher = """
    MATCH (n:Claim)
    WHERE n.human_validated = false
    RETURN n
    ORDER BY n.confidence ASC
    """

    case Graph.query(cypher) do
      {:ok, rows} -> {:ok, Enum.map(rows, &node_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all Claim nodes flagged as contested.
  """
  @spec list_contested() :: {:ok, [Node.t()]} | {:error, any()}
  def list_contested do
    case Graph.query("MATCH (n:Claim {contested: true}) RETURN n") do
      {:ok, rows} -> {:ok, Enum.map(rows, &node_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Traverses the supersession lineage forward from a given node id,
  returning the chain of nodes in order from oldest to newest.

  A node that has never been superseded returns a single-element list.
  """
  @spec lineage(String.t()) :: {:ok, [Node.t()]} | {:error, any()}
  def lineage(id) when is_binary(id) do
    # Walk the superseded_by chain by repeatedly fetching the next node.
    # We do this in Elixir rather than Cypher because superseded_by is
    # a property (not an edge), so there's no native path syntax for it.
    case get(id) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, start_node} ->
        chain = build_lineage_chain(start_node, [start_node], MapSet.new([id]))
        {:ok, chain}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Mutations
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new Claim node in Memgraph.

  Accepts either an `Xwa.Graph.Node` struct (already validated) or a plain
  map of attributes which will be passed through `Node.new/1`.

  Returns `{:ok, node}` with the persisted node, or `{:error, reason}`.
  """
  @spec create(Node.t() | map()) :: {:ok, Node.t()} | {:error, any()}
  def create(%Node{} = node) do
    params = Node.to_params(node)

    cypher = """
    CREATE (n:Claim)
    SET n = $props
    RETURN n
    """

    case Graph.query(cypher, %{props: params}) do
      {:ok, [row | _]} -> {:ok, node_from_row(row)}
      {:ok, []} -> {:error, :no_result}
      {:error, reason} -> {:error, reason}
    end
  end

  def create(attrs) when is_map(attrs) do
    case Node.new(attrs) do
      {:ok, node} -> create(node)
      {:error, reasons} -> {:error, {:validation, reasons}}
    end
  end

  @doc """
  Updates mutable fields on an existing Claim node.

  Only the fields present in `attrs` are changed. The `id` field is
  never updated — it is the stable graph identity.

  Allowed fields: `content`, `summary`, `type`, `tags`, `asserted_at`,
  `source_type`, `corpus_layer`, `confidence`, `human_validated`,
  `contested`, `public`, `encrypted`, `notes`.

  To modify `shared_with`, use `share_with/2` and `unshare_with/2`.
  """
  @spec update(String.t(), map()) :: {:ok, Node.t()} | {:error, any()}
  def update(id, attrs) when is_binary(id) and is_map(attrs) do
    allowed = ~w(
      content summary type tags asserted_at
      source_type corpus_layer confidence
      human_validated contested public encrypted notes
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
        |> Enum.map_join(", ", fn k -> "n.#{k} = $#{k}" end)

      cypher = """
      MATCH (n:Claim {id: $id})
      SET #{set_clauses}
      RETURN n
      """

      params = Map.put(updates, :id, id)

      case Graph.query(cypher, params) do
        {:ok, [row | _]} -> {:ok, node_from_row(row)}
        {:ok, []} -> {:error, :not_found}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Stores the embedding vector on a Claim node.

  This is intentionally separate from `update/2` because embeddings are
  set by the AI pipeline, not user edits, and may be large.
  """
  @spec set_embedding(String.t(), [float()]) :: :ok | {:error, any()}
  def set_embedding(id, embedding) when is_binary(id) and is_list(embedding) do
    cypher = """
    MATCH (n:Claim {id: $id})
    SET n.embedding = $embedding
    """

    Graph.run(cypher, %{id: id, embedding: embedding})
  end

  @doc """
  Marks a node as superseded by another node.

  Sets `superseded_by` on the old node to point to the new node's UUID.
  Neither node is deleted.
  """
  @spec supersede(String.t(), String.t()) :: :ok | {:error, any()}
  def supersede(old_id, new_id) when is_binary(old_id) and is_binary(new_id) do
    cypher = """
    MATCH (old:Claim {id: $old_id})
    MATCH (new:Claim {id: $new_id})
    SET old.superseded_by = $new_id
    """

    Graph.run(cypher, %{old_id: old_id, new_id: new_id})
  end

  @doc """
  Adds a user UUID to the `validated_by` list and sets `human_validated`
  to true. Idempotent — adding the same validator twice has no effect.
  """
  @spec validate_node(String.t(), String.t()) :: {:ok, Node.t()} | {:error, any()}
  def validate_node(node_id, user_id) when is_binary(node_id) and is_binary(user_id) do
    cypher = """
    MATCH (n:Claim {id: $node_id})
    SET n.human_validated = true,
        n.validated_by = CASE
          WHEN $user_id IN coalesce(n.validated_by, [])
          THEN n.validated_by
          ELSE coalesce(n.validated_by, []) + [$user_id]
        END
    RETURN n
    """

    case Graph.query(cypher, %{node_id: node_id, user_id: user_id}) do
      {:ok, [row | _]} -> {:ok, node_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Flags or unflags a node as contested.
  """
  @spec set_contested(String.t(), boolean()) :: :ok | {:error, any()}
  def set_contested(id, contested) when is_binary(id) and is_boolean(contested) do
    Graph.run(
      "MATCH (n:Claim {id: $id}) SET n.contested = $contested",
      %{id: id, contested: contested}
    )
  end

  @doc """
  Adds a user UUID to the `shared_with` list on a private node.
  Idempotent — adding the same user twice has no effect.
  Has no meaningful effect when `public` is true, but is safe to call.
  """
  @spec share_with(String.t(), String.t()) :: {:ok, Node.t()} | {:error, any()}
  def share_with(node_id, user_id) when is_binary(node_id) and is_binary(user_id) do
    cypher = """
    MATCH (n:Claim {id: $node_id})
    SET n.shared_with = CASE
      WHEN $user_id IN coalesce(n.shared_with, [])
      THEN n.shared_with
      ELSE coalesce(n.shared_with, []) + [$user_id]
    END
    RETURN n
    """

    case Graph.query(cypher, %{node_id: node_id, user_id: user_id}) do
      {:ok, [row | _]} -> {:ok, node_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Removes a user UUID from the `shared_with` list on a node.
  Idempotent — removing a user not in the list has no effect.
  """
  @spec unshare_with(String.t(), String.t()) :: {:ok, Node.t()} | {:error, any()}
  def unshare_with(node_id, user_id) when is_binary(node_id) and is_binary(user_id) do
    cypher = """
    MATCH (n:Claim {id: $node_id})
    SET n.shared_with = [u IN coalesce(n.shared_with, []) WHERE u <> $user_id]
    RETURN n
    """

    case Graph.query(cypher, %{node_id: node_id, user_id: user_id}) do
      {:ok, [row | _]} -> {:ok, node_from_row(row)}
      {:ok, []} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  MERGE a concept node by content — creates it if no node with
  `type: "concept"` and that exact `content` exists, otherwise returns
  the existing node.

  Used for `[[WikiLink]]` references: the same concept (e.g. "Christology")
  authored across multiple documents resolves to one shared node.
  """
  @spec merge_concept(map()) :: {:ok, Node.t()} | {:error, any()}
  def merge_concept(attrs) when is_map(attrs) do
    content = Map.fetch!(attrs, :content)

    cypher = """
    MERGE (n:Claim {type: "concept", content: $content})
    ON CREATE SET n += $props
    RETURN n
    """

    # Build a full props map but always force type/content for the MERGE key
    node_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    props =
      %{
        id: node_id,
        type: "concept",
        content: content,
        summary: Map.get(attrs, :summary, content),
        source_document_id: Map.get(attrs, :source_document_id),
        source_type: Map.get(attrs, :source_type),
        corpus_layer: Map.get(attrs, :corpus_layer),
        created_by: Map.get(attrs, :created_by),
        extracted_at: now,
        confidence: 1.0,
        ai_inferred: false,
        human_validated: false,
        contested: false,
        public: true,
        encrypted: false,
        tags: [],
        validated_by: [],
        shared_with: []
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.into(%{})

    case Graph.query(cypher, %{content: content, props: props}) do
      {:ok, [row | _]} -> {:ok, node_from_row(row)}
      {:ok, []} -> {:error, :no_result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a Claim node and all its relationships.
  """
  @spec delete(String.t()) :: :ok | {:error, any()}
  def delete(id) when is_binary(id) do
    Graph.run(
      "MATCH (n:Claim {id: $id}) DETACH DELETE n",
      %{id: id}
    )
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp node_from_row(%{"n" => bolt_node}), do: Node.from_bolt(bolt_node)
  defp node_from_row(row) when is_map(row), do: Node.from_bolt(row)

  defp build_lineage_chain(%Node{superseded_by: nil}, chain, _seen), do: Enum.reverse(chain)

  defp build_lineage_chain(%Node{superseded_by: next_id}, chain, seen) do
    if MapSet.member?(seen, next_id) do
      # Cycle guard — should not happen in a well-formed graph
      Enum.reverse(chain)
    else
      case get(next_id) do
        {:ok, nil} ->
          Enum.reverse(chain)

        {:ok, next_node} ->
          build_lineage_chain(next_node, [next_node | chain], MapSet.put(seen, next_id))

        {:error, _} ->
          Enum.reverse(chain)
      end
    end
  end
end
