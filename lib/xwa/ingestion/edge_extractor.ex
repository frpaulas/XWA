defmodule Xwa.Ingestion.EdgeExtractor do
  @moduledoc """
  Proposes relationships between a newly extracted claim and existing nodes
  in the graph by calling the Claude API with the edge extraction prompt.

  Called once per new claim node, immediately after it is inserted into
  Memgraph. The existing nodes passed in should be the most semantically
  relevant nodes already in the graph (not the full graph).

  ## Usage

      {:ok, edges, usage} = EdgeExtractor.extract(new_node, existing_nodes, %{
        document_id: doc.id,
        graph_id:    graph_id,
        created_by:  user_id
      })

  `usage` is a map with keys: `:input_tokens`, `:output_tokens`,
  `:finish_reason`, `:latency_ms`, `:model`.
  """

  alias Xwa.Graph.{Edge, Node}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Proposes edges between `new_node` and the list of `existing_nodes`.

  Returns `{:ok, [%Edge{}], usage_map}` or `{:error, reason}`.
  Returns `{:ok, [], %{}}` when the graph is empty or no relationships are found.
  """
  @spec extract(Node.t(), [Node.t()], map()) ::
          {:ok, [Edge.t()], map()} | {:error, term()}
  def extract(%Node{} = new_node, existing_nodes, context)
      when is_list(existing_nodes) and is_map(context) do
    if existing_nodes == [] do
      {:ok, [], %{}}
    else
      with {:ok, prompt} <- build_prompt(new_node, existing_nodes),
           {:ok, raw_json, usage} <- call_claude(prompt),
           {:ok, edges} <- parse_response(raw_json, new_node, context) do
        {:ok, edges, usage}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_prompt(%Node{} = new_node, existing_nodes) do
    template = prompt_template()

    new_claim_text = """
    id: #{new_node.id}
    summary: #{new_node.summary}
    content: #{new_node.content}
    type: #{new_node.type}
    """

    existing_nodes_text =
      existing_nodes
      |> Enum.map(fn n ->
        "id: #{n.id}\nsummary: #{n.summary}\ncontent: #{n.content}"
      end)
      |> Enum.join("\n\n---\n\n")

    prompt =
      template
      |> String.replace("{{new_claim}}", String.trim(new_claim_text))
      |> String.replace("{{existing_nodes}}", existing_nodes_text)

    {:ok, prompt}
  end

  defp call_claude(prompt) do
    api_key =
      Application.get_env(:xwa, :anthropic_api_key) ||
        System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      {:error, :anthropic_api_key_not_configured}
    else
      body = %{
        model: model(),
        max_tokens: 4096,
        messages: [%{role: "user", content: prompt}]
      }

      t0 = System.monotonic_time(:millisecond)

      result =
        Req.post("https://api.anthropic.com/v1/messages",
          json: body,
          headers: [
            {"x-api-key", api_key},
            {"anthropic-version", "2023-06-01"}
          ],
          receive_timeout: 60_000
        )

      latency_ms = System.monotonic_time(:millisecond) - t0

      case result do
        {:ok, %{status: 200, body: resp_body}} ->
          usage = %{
            input_tokens: get_in(resp_body, ["usage", "input_tokens"]),
            output_tokens: get_in(resp_body, ["usage", "output_tokens"]),
            finish_reason: resp_body["stop_reason"],
            latency_ms: latency_ms,
            model: resp_body["model"] || model()
          }

          case extract_text_from_response(resp_body) do
            {:ok, text} -> {:ok, text, usage}
            error -> error
          end

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:api_error, status, resp_body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end
  end

  defp extract_text_from_response(%{"content" => [%{"text" => text} | _]}), do: {:ok, text}
  defp extract_text_from_response(body), do: {:error, {:unexpected_response, body}}

  defp parse_response(raw, new_node, context) do
    json_str = extract_json(raw)

    with {:ok, %{"edges" => edges}} when is_list(edges) <- Jason.decode(json_str) do
      document_id = Map.get(context, :document_id)
      created_by = Map.get(context, :created_by)
      graph_id = Map.get(context, :graph_id)

      result =
        edges
        |> Enum.map(&edge_to_attrs(&1, new_node.id, document_id, created_by, graph_id))
        |> Enum.flat_map(fn attrs ->
          case Edge.new(attrs) do
            {:ok, edge} -> [edge]
            {:error, _} -> []
          end
        end)

      {:ok, result}
    else
      {:ok, _} -> {:error, :missing_edges_key}
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  defp extract_json(text) do
    case Regex.run(~r/```(?:json)?\s*([\s\S]*?)```/m, text, capture: :all_but_first) do
      [json] -> String.trim(json)
      nil -> String.trim(text)
    end
  end

  defp edge_to_attrs(edge, new_node_id, document_id, created_by, graph_id) do
    to_id =
      case edge["to_node_id"] do
        "NEW" -> new_node_id
        other -> other
      end

    %{
      from_node_id: edge["from_node_id"],
      to_node_id: to_id,
      type: edge["type"],
      label: edge["label"],
      directed: edge["directed"] != false,
      importance: edge["importance"] || 0.5,
      certainty: edge["certainty"] || "dashed",
      confidence: edge["confidence"] || 0.5,
      source_document_ids: if(document_id, do: [document_id], else: []),
      created_by: created_by,
      ai_inferred: true,
      human_validated: false,
      graph_id: graph_id,
      visibility: "system"
    }
  end

  defp prompt_template do
    path = Application.app_dir(:xwa, "priv/prompts/edge_extraction.md")

    case File.read(path) do
      {:ok, content} ->
        content

      {:error, _} ->
        File.read!(Path.join([:code.priv_dir(:xwa), "../..", "prompts", "edge_extraction.md"]))
    end
  end

  defp model do
    Application.get_env(:xwa, :claude_model, "claude-sonnet-4-6")
  end
end
