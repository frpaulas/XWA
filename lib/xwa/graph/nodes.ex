defmodule Xwa.Graph.Nodes do
  @moduledoc """
  Context for managing Claim nodes in the Memgraph knowledge graph.

  All persistence goes through `Xwa.Graph` (the Bolt.Sips wrapper).
  This module owns the Cypher queries and maps results to and from
  `Xwa.Graph.Node` structs.

  ## Graph tenancy

  Every node carries a `graph_id` property that scopes it to a single
  Postgres Graph record. All list/query functions that accept a `graph_id`
  filter on it. Functions without a `graph_id` argument operate across all
  graphs and should only be called from internal pipeline code.

  ## Node identity

  Nodes are identified by the `id` property (a UUID string), not
  Memgraph's internal element id. All lookups use `id` so that the
  graph can be backed up, restored, or migrated without losing
  referential integrity.
  """

  alias Xwa.Graph
  alias Xwa.Graph.Node

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns all Claim nodes in one or more graphs, respecting visibility rules
  for the requesting user:
  - "system" nodes are visible to all members
  - "private" nodes are only visible to their creator
  - "shared" nodes are visible to all members (shared_with is empty) or to
    the users listed in shared_with

  `graph_id` may be a single binary UUID or a list of UUIDs (for composite
  graphs resolved via `Xwa.Graphs.resolve_graph_ids/1`).

  Pass `user_id: nil` to skip visibility filtering (internal use only).
  """
  @spec list(String.t() | [String.t()], keyword()) :: {:ok, [Node.t()]} | {:error, any()}
  def list(graph_id, opts \\ [])

  def list(graph_id, opts) when is_binary(graph_id) do
    list([graph_id], opts)
  end

  def list(graph_ids, opts) when is_list(graph_ids) do
    user_id = Keyword.get(opts, :user_id)

    cypher = """
    MATCH (n:Claim)
    WHERE n.graph_id IN $graph_ids
      AND (n.visibility = 'system'
        OR n.created_by = $user_id
        OR (n.visibility = 'shared' AND (size(coalesce(n.shared_with, [])) = 0 OR $user_id IN coalesce(n.shared_with, []))))
    RETURN n
    """

    params = %{graph_ids: graph_ids, user_id: user_id}

    case Graph.query(cypher, params) do
      {:ok, rows} -> {:ok, Enum.map(rows, &node_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the 2-hop neighborhood of a node: the node itself, all nodes within
  2 hops, and all edges between them. Respects visibility for the requesting user.

  `graph_id` may be a single binary UUID or a list of UUIDs (for composite
  graphs resolved via `Xwa.Graphs.resolve_graph_ids/1`).

  Returns `{:ok, %{nodes: [Node.t()], edges: [Edge.t()]}}`.
  """
  @spec neighborhood(String.t(), String.t() | [String.t()], keyword()) ::
          {:ok, %{nodes: [Node.t()], edges: [Xwa.Graph.Edge.t()]}} | {:error, any()}
  def neighborhood(node_id, graph_id, opts \\ [])

  def neighborhood(node_id, graph_id, opts) when is_binary(graph_id) do
    neighborhood(node_id, [graph_id], opts)
  end

  def neighborhood(node_id, graph_ids, opts) when is_list(graph_ids) do
    user_id = Keyword.get(opts, :user_id)

    node_visibility =
      if user_id do
        """
        AND (nb.visibility = 'system' OR nb.created_by = $user_id
          OR (nb.visibility = 'shared' AND (size(coalesce(nb.shared_with, [])) = 0 OR $user_id IN coalesce(nb.shared_with, []))))
        """
      else
        ""
      end

    edge_visibility =
      if user_id do
        """
        AND (r.visibility = 'system' OR r.created_by = $user_id
          OR (r.visibility = 'shared' AND (size(coalesce(r.shared_with, [])) = 0 OR $user_id IN coalesce(r.shared_with, []))))
        AND NOT $user_id IN coalesce(r.hidden_by, [])
        """
      else
        ""
      end

    node_cypher = """
    MATCH (center:Claim {id: $node_id})-[:RELATES]-(nb:Claim)
    WHERE center.graph_id IN $graph_ids AND nb.graph_id IN $graph_ids
    #{node_visibility}
    RETURN DISTINCT nb AS n
    UNION
    MATCH (n:Claim {id: $node_id})
    WHERE n.graph_id IN $graph_ids
    RETURN n
    """

    edge_cypher = """
    MATCH (center:Claim {id: $node_id})-[:RELATES]-(nb:Claim)
    WHERE center.graph_id IN $graph_ids AND nb.graph_id IN $graph_ids
    WITH collect(DISTINCT nb) + [center] AS hood
    UNWIND hood AS a
    UNWIND hood AS b
    MATCH (a)-[r:RELATES]->(b)
    WHERE r.graph_id IN $graph_ids
    #{edge_visibility}
    RETURN DISTINCT r
    """

    params = %{node_id: node_id, graph_ids: graph_ids, user_id: user_id}

    with {:ok, node_rows} <- Graph.query(node_cypher, params),
         {:ok, edge_rows} <- Graph.query(edge_cypher, params) do
      nodes = Enum.map(node_rows, &node_from_row/1)
      edges = Enum.map(edge_rows, &Xwa.Graph.Edges.from_bolt(&1["r"]))
      {:ok, %{nodes: nodes, edges: edges}}
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
  Returns all Claim nodes in a graph referencing a given source document UUID.
  """
  @spec list_by_document(String.t(), String.t()) :: {:ok, [Node.t()]} | {:error, any()}
  def list_by_document(graph_id, document_id)
      when is_binary(graph_id) and is_binary(document_id) do
    cypher = """
    MATCH (n:Claim {graph_id: $graph_id, source_document_id: $document_id})
    RETURN n
    ORDER BY n.asserted_at ASC
    """

    case Graph.query(cypher, %{graph_id: graph_id, document_id: document_id}) do
      {:ok, rows} -> {:ok, Enum.map(rows, &node_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all Claim nodes in a graph with a given corpus_layer value.
  """
  @spec list_by_corpus_layer(String.t(), String.t()) :: {:ok, [Node.t()]} | {:error, any()}
  def list_by_corpus_layer(graph_id, layer)
      when is_binary(graph_id) and is_binary(layer) do
    cypher = """
    MATCH (n:Claim {graph_id: $graph_id, corpus_layer: $layer})
    RETURN n
    """

    case Graph.query(cypher, %{graph_id: graph_id, layer: layer}) do
      {:ok, rows} -> {:ok, Enum.map(rows, &node_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all Claim nodes in a graph awaiting human validation.
  """
  @spec list_unvalidated(String.t()) :: {:ok, [Node.t()]} | {:error, any()}
  def list_unvalidated(graph_id) when is_binary(graph_id) do
    cypher = """
    MATCH (n:Claim {graph_id: $graph_id})
    WHERE n.human_validated = false
    RETURN n
    ORDER BY n.confidence ASC
    """

    case Graph.query(cypher, %{graph_id: graph_id}) do
      {:ok, rows} -> {:ok, Enum.map(rows, &node_from_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all Claim nodes in a graph flagged as contested.
  """
  @spec list_contested(String.t()) :: {:ok, [Node.t()]} | {:error, any()}
  def list_contested(graph_id) when is_binary(graph_id) do
    cypher = """
    MATCH (n:Claim {graph_id: $graph_id, contested: true})
    RETURN n
    """

    case Graph.query(cypher, %{graph_id: graph_id}) do
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
  `contested`, `public`, `encrypted`, `visibility`, `notes`.
  """
  @spec update(String.t(), map()) :: {:ok, Node.t()} | {:error, any()}
  def update(id, attrs) when is_binary(id) and is_map(attrs) do
    allowed = ~w(
      content summary type tags asserted_at
      source_type corpus_layer confidence
      human_validated contested public encrypted
      visibility notes
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
  to true. Idempotent.
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
  Adds a user UUID to the `shared_with` list on a node. Idempotent.
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
  Removes a user UUID from the `shared_with` list on a node. Idempotent.
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
  MERGE a concept node by content within a graph — creates it if no node with
  `type: "concept"` and that exact `content` and `graph_id` exists, otherwise
  returns the existing node.

  Used for `[[WikiLink]]` references.
  """
  @spec merge_concept(map()) :: {:ok, Node.t()} | {:error, any()}
  def merge_concept(attrs) when is_map(attrs) do
    content = Map.fetch!(attrs, :content)
    graph_id = Map.get(attrs, :graph_id)

    cypher = """
    MERGE (n:Claim {type: "concept", content: $content, graph_id: $graph_id})
    ON CREATE SET n += $props
    RETURN n
    """

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
        shared_with: [],
        graph_id: graph_id,
        visibility: "system"
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.into(%{})

    case Graph.query(cypher, %{content: content, graph_id: graph_id, props: props}) do
      {:ok, [row | _]} -> {:ok, node_from_row(row)}
      {:ok, []} -> {:error, :no_result}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns `{id, embedding}` pairs for all nodes in the given graph(s) that
  have a non-nil embedding. Intentionally lean — does not load other fields.

  Used by `SimilarityMerger` to build the cross-graph similarity matrix.
  """
  @spec list_embeddings(String.t() | [String.t()]) ::
          {:ok, [{String.t(), [float()]}]} | {:error, any()}
  def list_embeddings(graph_id) when is_binary(graph_id), do: list_embeddings([graph_id])

  def list_embeddings(graph_ids) when is_list(graph_ids) do
    cypher = """
    MATCH (n:Claim)
    WHERE n.graph_id IN $graph_ids AND n.embedding IS NOT NULL
    RETURN n.id AS id, n.embedding AS embedding
    """

    case Graph.query(cypher, %{graph_ids: graph_ids}) do
      {:ok, rows} ->
        pairs = Enum.map(rows, fn %{"id" => id, "embedding" => emb} -> {id, emb} end)
        {:ok, pairs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns `{id, text}` pairs for nodes in the given graph(s) that have no
  embedding yet. `text` is `summary` if present, otherwise `content`.

  Used by the backfill task and ingestion worker to know what to embed.
  """
  @spec list_missing_embeddings(String.t() | [String.t()]) ::
          {:ok, [{String.t(), String.t()}]} | {:error, any()}
  def list_missing_embeddings(graph_id) when is_binary(graph_id) do
    list_missing_embeddings([graph_id])
  end

  def list_missing_embeddings(graph_ids) when is_list(graph_ids) do
    cypher = """
    MATCH (n:Claim)
    WHERE n.graph_id IN $graph_ids AND n.embedding IS NULL
    RETURN n.id AS id, coalesce(n.summary, n.content) AS text
    """

    case Graph.query(cypher, %{graph_ids: graph_ids}) do
      {:ok, rows} ->
        pairs =
          rows
          |> Enum.filter(fn %{"text" => text} -> is_binary(text) and text != "" end)
          |> Enum.map(fn %{"id" => id, "text" => text} -> {id, text} end)

        {:ok, pairs}

      {:error, reason} ->
        {:error, reason}
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

  @doc """
  Deletes all Claim nodes (and their relationships) sourced from a given document.
  """
  @spec delete_by_document(String.t(), String.t()) :: :ok | {:error, any()}
  def delete_by_document(graph_id, document_id)
      when is_binary(graph_id) and is_binary(document_id) do
    Graph.run(
      "MATCH (n:Claim {graph_id: $graph_id, source_document_id: $document_id}) DETACH DELETE n",
      %{graph_id: graph_id, document_id: document_id}
    )
  end

  # ---------------------------------------------------------------------------
  # ILV calibration
  # ---------------------------------------------------------------------------

  @doc """
  Returns all Claim nodes in a graph as `%{id: string, content: string}` maps.
  No visibility filtering — intended for internal calibration use only.
  """
  @spec list_all_claims(String.t()) ::
          {:ok, [%{id: String.t(), content: String.t(), confidence: float()}]} | {:error, any()}
  def list_all_claims(graph_id) when is_binary(graph_id) do
    cypher = """
    MATCH (n:Claim {graph_id: $graph_id})
    WHERE n.content IS NOT NULL AND n.content <> ''
    RETURN n.id AS id, n.content AS content, coalesce(n.confidence, 1.0) AS confidence
    """

    case Graph.query(cypher, %{graph_id: graph_id}) do
      {:ok, rows} ->
        claims =
          rows
          |> Enum.map(fn %{"id" => id, "content" => content, "confidence" => conf} ->
            %{id: id, content: content, confidence: conf * 1.0}
          end)
          |> Enum.reject(fn %{content: c} -> is_nil(c) or String.trim(c) == "" end)

        {:ok, claims}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stores the ILV score, fingerprint, adjusted confidence, and gaming flag on a Claim node.
  `fingerprint` should be `%{w: float, x: float, y: float, z: float}`.
  `adjusted_confidence` replaces the node's existing confidence value.
  `gaming_flag` is true when the claim scores well overall but has a significant negative
  outlier on one axis — a potential mixed-signal pattern.
  """
  @spec set_ilv(String.t(), float(), map(), float(), boolean()) :: :ok | {:error, any()}
  def set_ilv(id, score, fingerprint, adjusted_confidence, gaming_flag)
      when is_binary(id) and is_float(score) and is_map(fingerprint) do
    cypher = """
    MATCH (n:Claim {id: $id})
    SET n.ilv_score = $score,
        n.ilv_fingerprint = $fingerprint,
        n.confidence = $adjusted_confidence,
        n.gaming_flag = $gaming_flag
    """

    Graph.run(cypher, %{
      id: id,
      score: score,
      fingerprint: %{
        "w" => Map.get(fingerprint, :w) || Map.get(fingerprint, "w") || 0.5,
        "x" => Map.get(fingerprint, :x) || Map.get(fingerprint, "x") || 0.5,
        "y" => Map.get(fingerprint, :y) || Map.get(fingerprint, "y") || 0.5,
        "z" => Map.get(fingerprint, :z) || Map.get(fingerprint, "z") || 0.5
      },
      adjusted_confidence: adjusted_confidence,
      gaming_flag: gaming_flag
    })
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp node_from_row(%{"n" => bolt_node}), do: Node.from_bolt(bolt_node)
  defp node_from_row(row) when is_map(row), do: Node.from_bolt(row)

  defp build_lineage_chain(%Node{superseded_by: nil}, chain, _seen), do: Enum.reverse(chain)

  defp build_lineage_chain(%Node{superseded_by: next_id}, chain, seen) do
    if MapSet.member?(seen, next_id) do
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
