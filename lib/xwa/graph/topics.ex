defmodule Xwa.Graph.Topics do
  @moduledoc """
  Context for managing topic nodes and BELONGS_TO / topic-RELATES edges.

  Topics are org-scoped `:Claim` nodes with `node_type: "topic"` and
  `graph_id: nil`.  They are deduplicated by cosine similarity at creation
  time so semantically equivalent topics from different graphs share one node.

  ## Edge types

  - Claim → Topic: `:RELATES` edge with `type: "belongs_to"`, `graph_id` =
    claim's `graph_id` so it can be loaded per-graph.
  - Topic → Topic: `:RELATES` edge with Claude-proposed type, `graph_id: nil`
    so it spans the whole organisation.
  """

  require Logger

  alias Xwa.Graph
  alias Xwa.Graph.{Node, Nodes, Edges, VectorMath}
  alias Xwa.Ingestion.VoyageEmbedder

  @sim_threshold 0.70

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns all topic nodes for an organisation.
  """
  @spec list(String.t()) :: {:ok, [Node.t()]} | {:error, any()}
  defdelegate list(org_id), to: Nodes, as: :list_topics

  @doc """
  Returns all BELONGS_TO edges for claims in the given graph(s).
  Each edge has `type: "belongs_to"` and connects a claim to its topic.
  """
  @spec list_belongs_to_edges(String.t() | [String.t()]) ::
          {:ok, [Xwa.Graph.Edge.t()]} | {:error, any()}
  def list_belongs_to_edges(graph_id) when is_binary(graph_id),
    do: list_belongs_to_edges([graph_id])

  def list_belongs_to_edges(graph_ids) when is_list(graph_ids) do
    cypher = """
    MATCH ()-[r:RELATES {type: "belongs_to"}]->()
    WHERE r.graph_id IN $graph_ids
    RETURN r
    """

    case Graph.query(cypher, %{graph_ids: graph_ids}) do
      {:ok, rows} -> {:ok, Enum.map(rows, &Edges.from_bolt(&1["r"]))}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns all topic→topic edges for an organisation (`graph_id: nil` edges
  where both endpoints are topic nodes in the given org).
  """
  @spec list_topic_edges(String.t()) :: {:ok, [Xwa.Graph.Edge.t()]} | {:error, any()}
  def list_topic_edges(org_id) when is_binary(org_id) do
    cypher = """
    MATCH (a:Claim {node_type: "topic", organization_id: $org_id})-[r:RELATES]->(b:Claim {node_type: "topic"})
    WHERE r.graph_id IS NULL
    RETURN r
    """

    case Graph.query(cypher, %{org_id: org_id}) do
      {:ok, rows} -> {:ok, Enum.map(rows, &Edges.from_bolt(&1["r"]))}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Mutations
  # ---------------------------------------------------------------------------

  @doc """
  Finds an existing topic with cosine similarity ≥ #{@sim_threshold} to
  `topic_text`, or creates a new topic node.

  Returns `{:ok, node, :existing | :created}`.
  """
  @spec find_or_create(String.t(), String.t(), keyword()) ::
          {:ok, Node.t(), :existing | :created} | {:error, any()}
  def find_or_create(topic_text, org_id, opts \\ []) do
    created_by = Keyword.get(opts, :created_by)

    # Embed the candidate topic text
    case VoyageEmbedder.embed([topic_text]) do
      {:ok, [embedding], _usage} ->
        find_similar_or_create(topic_text, embedding, org_id, created_by)

      {:error, :voyage_api_key_not_configured} ->
        # No embedding — fall back to exact-text match then create
        find_by_content_or_create(topic_text, org_id, created_by)

      {:error, reason} ->
        Logger.warning("[Topics] Embedding failed for '#{topic_text}': #{inspect(reason)}")
        find_by_content_or_create(topic_text, org_id, created_by)
    end
  end

  @doc """
  Creates a `:RELATES` edge with `type: "belongs_to"` from `claim_id` to
  `topic_id`, scoped to `graph_id`.  Idempotent — does nothing if the edge
  already exists.
  """
  @spec assign_topic(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, any()}
  def assign_topic(claim_id, topic_id, graph_id, created_by) do
    cypher = """
    MATCH (c:Claim {id: $claim_id})
    MATCH (t:Claim {id: $topic_id, node_type: "topic"})
    MERGE (c)-[r:RELATES {type: "belongs_to", from_node_id: $claim_id, to_node_id: $topic_id, graph_id: $graph_id}]->(t)
    ON CREATE SET
      r.id            = $edge_id,
      r.created_by    = $created_by,
      r.visibility    = "system",
      r.confidence    = 1.0,
      r.importance    = 0.5,
      r.certainty     = "solid",
      r.directed      = true,
      r.ai_inferred   = true,
      r.human_validated = false,
      r.contested     = false,
      r.source_document_ids = []
    """

    params = %{
      claim_id: claim_id,
      topic_id: topic_id,
      graph_id: graph_id,
      created_by: created_by,
      edge_id: Ecto.UUID.generate()
    }

    Graph.run(cypher, params)
  end

  @doc """
  Creates topic→topic edges proposed by Claude for a newly created topic.
  `existing_topics` is a list of `%Node{}` topic nodes.
  Each edge in `proposed` is a map with keys: `to_node_id`, `type`, `label`,
  `confidence`, `certainty`, `importance`.
  """
  @spec create_topic_edges([map()], String.t(), String.t()) :: :ok
  def create_topic_edges(proposed_edges, org_id, created_by) do
    Enum.each(proposed_edges, fn edge ->
      cypher = """
      MATCH (a:Claim {id: $from_id, node_type: "topic", organization_id: $org_id})
      MATCH (b:Claim {id: $to_id,   node_type: "topic", organization_id: $org_id})
      MERGE (a)-[r:RELATES {type: $type, from_node_id: $from_id, to_node_id: $to_id, graph_id: null}]->(b)
      ON CREATE SET
        r.id            = $edge_id,
        r.label         = $label,
        r.confidence    = $confidence,
        r.importance    = $importance,
        r.certainty     = $certainty,
        r.directed      = true,
        r.visibility    = "system",
        r.created_by    = $created_by,
        r.ai_inferred   = true,
        r.human_validated = false,
        r.contested     = false,
        r.source_document_ids = []
      """

      params = %{
        from_id:    edge.from_node_id,
        to_id:      edge.to_node_id,
        org_id:     org_id,
        type:       edge.type || "relates",
        label:      edge.label || "",
        confidence: edge.confidence || 0.7,
        importance: edge.importance || 0.5,
        certainty:  edge.certainty || "dashed",
        created_by: created_by,
        edge_id:    Ecto.UUID.generate()
      }

      case Graph.run(cypher, params) do
        :ok -> :ok
        {:error, reason} ->
          Logger.warning("[Topics] Failed to create topic edge: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp find_similar_or_create(topic_text, embedding, org_id, created_by) do
    case Nodes.list_topic_embeddings(org_id) do
      {:ok, []} ->
        create_topic(topic_text, embedding, org_id, created_by)

      {:ok, existing_pairs} ->
        norm_new = VectorMath.normalize(embedding)

        best =
          existing_pairs
          |> Enum.map(fn {id, emb} ->
            score = VectorMath.dot_product(norm_new, VectorMath.normalize(emb))
            {id, score}
          end)
          |> Enum.max_by(fn {_id, score} -> score end)

        {best_id, best_score} = best

        if best_score >= @sim_threshold do
          case Nodes.get(best_id) do
            {:ok, node} when not is_nil(node) -> {:ok, node, :existing}
            _ -> create_topic(topic_text, embedding, org_id, created_by)
          end
        else
          create_topic(topic_text, embedding, org_id, created_by)
        end

      {:error, reason} ->
        Logger.warning("[Topics] Could not load topic embeddings: #{inspect(reason)}")
        create_topic(topic_text, embedding, org_id, created_by)
    end
  end

  defp find_by_content_or_create(topic_text, org_id, created_by) do
    cypher = """
    MATCH (n:Claim {node_type: "topic", organization_id: $org_id, content: $content})
    RETURN n LIMIT 1
    """

    case Graph.query(cypher, %{org_id: org_id, content: topic_text}) do
      {:ok, [row | _]} -> {:ok, Node.from_bolt(row["n"]), :existing}
      {:ok, []} -> create_topic(topic_text, nil, org_id, created_by)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_topic(topic_text, embedding, org_id, created_by) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    node_id = Ecto.UUID.generate()

    props =
      %{
        id: node_id,
        content: topic_text,
        summary: topic_text,
        node_type: "topic",
        organization_id: org_id,
        graph_id: nil,
        created_by: created_by,
        extracted_at: now,
        confidence: 1.0,
        ai_inferred: true,
        human_validated: false,
        contested: false,
        public: true,
        encrypted: false,
        tags: [],
        validated_by: [],
        shared_with: [],
        visibility: "system"
      }
      |> then(fn p -> if embedding, do: Map.put(p, :embedding, embedding), else: p end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.into(%{})

    cypher = """
    CREATE (n:Claim)
    SET n = $props
    RETURN n
    """

    case Graph.query(cypher, %{props: props}) do
      {:ok, [row | _]} -> {:ok, Node.from_bolt(row["n"]), :created}
      {:ok, []} -> {:error, :no_result}
      {:error, reason} -> {:error, reason}
    end
  end
end
