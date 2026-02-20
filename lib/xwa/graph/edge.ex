defmodule Xwa.Graph.Edge do
  @moduledoc """
  Struct representing a relationship edge between two Claim nodes
  in the Memgraph knowledge graph.

  Edges are stored in Memgraph as relationships with the universal
  Cypher type `:RELATES`. The emergent, domain-specific `type` field
  is stored as a property so that the ontology can grow organically
  without requiring schema changes.

  ## Directionality

  Cypher relationships are always physically directed (from → to).
  When `directed` is false the relationship is semantically bidirectional.
  Queries should use the undirected pattern `(a)-[:RELATES]-(b)` for
  these edges rather than `(a)-[:RELATES]->(b)`.

  ## Visual encoding

  - `importance` (0.0–1.0) drives edge colour in the graph UI
  - `certainty` (:solid | :dashed | :dotted) drives line style

  ## Epistemic metadata

  Mirrors the node pattern: AI-inferred by default, confidence improves
  through human validation, `contested` is a separate signal from low
  confidence — it means users actively disagree, not that we're unsure.

  ## Source provenance

  `source_document_ids` is a list because a relationship evidenced across
  multiple documents carries stronger grounds for confidence than a single
  source. Cross-document evidence is a first-class signal.
  """

  @certainty_values ~w(solid dashed dotted)

  defstruct [
    # Identity
    :id,
    :from_node_id,
    :to_node_id,

    # Relationship semantics
    :type,
    :label,

    # Provenance
    :established_at,
    :extracted_at,

    # Audit
    :created_by,
    :notes,

    # Fields with defaults must come last
    source_document_ids: [],
    validated_by: [],
    hidden_by: [],
    directed: true,
    importance: 0.5,
    certainty: "solid",
    confidence: 1.0,
    ai_inferred: true,
    human_validated: false,
    contested: false,
    # Multi-graph tenancy
    # visibility: "system"  = AI-extracted, visible to all graph members;
    #             "private" = only visible to created_by user;
    #             "shared"  = visible to members in shared_with (all if empty)
    graph_id: nil,
    visibility: "system"
  ]

  @type certainty :: String.t()

  @type t :: %__MODULE__{
          id: String.t() | nil,
          from_node_id: String.t() | nil,
          to_node_id: String.t() | nil,
          type: String.t() | nil,
          label: String.t() | nil,
          directed: boolean(),
          importance: float(),
          certainty: certainty(),
          confidence: float(),
          ai_inferred: boolean(),
          human_validated: boolean(),
          contested: boolean(),
          source_document_ids: [String.t()],
          established_at: String.t() | nil,
          extracted_at: String.t() | nil,
          created_by: String.t() | nil,
          validated_by: [String.t()],
          hidden_by: [String.t()],
          notes: String.t() | nil,
          graph_id: String.t() | nil,
          visibility: String.t()
        }

  @doc """
  Builds a new Edge struct from a map of attributes, generating a UUID
  and setting `extracted_at` to now if not provided.

  Returns `{:ok, edge}` or `{:error, reasons}` where reasons is a list
  of human-readable validation error strings.
  """
  @spec new(map()) :: {:ok, t()} | {:error, [String.t()]}
  def new(attrs) when is_map(attrs) do
    edge = %__MODULE__{
      id: Map.get(attrs, :id) || generate_uuid(),
      from_node_id: Map.get(attrs, :from_node_id),
      to_node_id: Map.get(attrs, :to_node_id),
      type: Map.get(attrs, :type),
      label: Map.get(attrs, :label),
      directed: Map.get(attrs, :directed, true),
      importance: Map.get(attrs, :importance, 0.5),
      certainty: Map.get(attrs, :certainty, "solid"),
      confidence: Map.get(attrs, :confidence, 1.0),
      ai_inferred: Map.get(attrs, :ai_inferred, true),
      human_validated: Map.get(attrs, :human_validated, false),
      contested: Map.get(attrs, :contested, false),
      source_document_ids: Map.get(attrs, :source_document_ids, []),
      established_at: Map.get(attrs, :established_at),
      extracted_at: Map.get(attrs, :extracted_at) || utc_now_iso(),
      created_by: Map.get(attrs, :created_by),
      validated_by: Map.get(attrs, :validated_by, []),
      notes: Map.get(attrs, :notes),
      graph_id: Map.get(attrs, :graph_id),
      visibility: Map.get(attrs, :visibility, "system")
    }

    case validate(edge) do
      [] -> {:ok, edge}
      errors -> {:error, errors}
    end
  end

  @doc """
  Like `new/1` but raises on validation failure.
  """
  @spec new!(map()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, edge} -> edge
      {:error, errors} -> raise ArgumentError, "invalid edge: #{Enum.join(errors, ", ")}"
    end
  end

  @doc """
  Converts a `Bolt.Sips.Types.Relationship` (as returned from a Cypher
  query result) into an `Xwa.Graph.Edge` struct.

  Bolt.Sips returns relationship properties as a plain map with string
  keys. Pass the relationship value from the result row directly:

      {:ok, rows} = Xwa.Graph.query("MATCH ()-[r:RELATES {id: $id}]->() RETURN r", %{id: id})
      edge = Xwa.Graph.Edge.from_bolt(rows |> List.first() |> Map.get("r"))
  """
  @spec from_bolt(Bolt.Sips.Types.Relationship.t() | map()) :: t()
  def from_bolt(%Bolt.Sips.Types.Relationship{properties: props}) do
    from_properties(props)
  end

  def from_bolt(%{"properties" => props}) do
    from_properties(props)
  end

  def from_bolt(props) when is_map(props) do
    from_properties(props)
  end

  @doc """
  Converts the edge struct into a plain map suitable for use as Cypher
  parameters. Nil values are excluded so Memgraph does not store
  unnecessary null properties.
  """
  @spec to_params(t()) :: map()
  def to_params(%__MODULE__{} = edge) do
    edge
    |> Map.from_struct()
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp from_properties(props) when is_map(props) do
    %__MODULE__{
      id: props["id"],
      from_node_id: props["from_node_id"],
      to_node_id: props["to_node_id"],
      type: props["type"],
      label: props["label"],
      directed: Map.get(props, "directed", true),
      importance: Map.get(props, "importance", 0.5),
      certainty: Map.get(props, "certainty", "solid"),
      confidence: Map.get(props, "confidence", 1.0),
      ai_inferred: Map.get(props, "ai_inferred", true),
      human_validated: Map.get(props, "human_validated", false),
      contested: Map.get(props, "contested", false),
      source_document_ids: Map.get(props, "source_document_ids", []),
      established_at: props["established_at"],
      extracted_at: props["extracted_at"],
      created_by: props["created_by"],
      validated_by: Map.get(props, "validated_by", []),
      hidden_by: Map.get(props, "hidden_by", []),
      notes: props["notes"],
      graph_id: props["graph_id"],
      visibility: Map.get(props, "visibility", "system")
    }
  end

  defp validate(%__MODULE__{} = edge) do
    []
    |> require(:from_node_id, edge.from_node_id)
    |> require(:to_node_id, edge.to_node_id)
    |> require(:type, edge.type)
    |> validate_not_self_loop(edge.from_node_id, edge.to_node_id)
    |> validate_inclusion(:certainty, edge.certainty, @certainty_values)
    |> validate_float_range(:importance, edge.importance, 0.0, 1.0)
    |> validate_float_range(:confidence, edge.confidence, 0.0, 1.0)
  end

  defp require(errors, _field, value) when is_binary(value) and value != "", do: errors
  defp require(errors, field, _), do: ["#{field} is required" | errors]

  defp validate_not_self_loop(errors, from, to)
       when is_binary(from) and is_binary(to) and from == to,
       do: ["from_node_id and to_node_id must be different nodes" | errors]

  defp validate_not_self_loop(errors, _from, _to), do: errors

  defp validate_inclusion(errors, field, value, valid) do
    if value in valid do
      errors
    else
      ["#{field} must be one of: #{Enum.join(valid, ", ")}" | errors]
    end
  end

  defp validate_float_range(errors, _field, value, min, max)
       when is_float(value) and value >= min and value <= max,
       do: errors

  defp validate_float_range(errors, _field, value, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: errors

  defp validate_float_range(errors, field, _value, min, max),
    do: ["#{field} must be a float between #{min} and #{max}" | errors]

  defp generate_uuid, do: Ecto.UUID.generate()

  defp utc_now_iso do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
