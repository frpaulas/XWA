defmodule Xwa.Ingestion.TopicExtractor do
  @moduledoc """
  Extracts a topic label for a single claim and proposes topic→topic edges
  for newly created topics.

  ## Usage

      # Get a topic label for a claim
      {:ok, "LPO loan program oversight"} = TopicExtractor.extract_topic(claim_content)

      # Propose edges between a new topic and existing topics
      {:ok, edges} = TopicExtractor.extract_topic_edges(new_topic, existing_topics)
  """

  require Logger

  @topic_prompt_path Path.join(:code.priv_dir(:xwa), "prompts/topic_extraction.md")
  @external_resource @topic_prompt_path

  @edge_prompt_path Path.join(:code.priv_dir(:xwa), "prompts/topic_edge_extraction.md")
  @external_resource @edge_prompt_path

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Extracts a topic label for the given claim content.
  Returns `{:ok, topic_label}` or `{:error, reason}`.
  """
  @spec extract_topic(String.t()) :: {:ok, String.t()} | {:error, term()}
  def extract_topic(claim_content) when is_binary(claim_content) do
    template = topic_prompt_template()
    prompt = String.replace(template, "{{claim_content}}", claim_content)

    with {:ok, raw, _usage} <- call_claude(prompt),
         {:ok, %{"topic" => label}} when is_binary(label) <- Jason.decode(extract_json(raw)) do
      {:ok, String.trim(label)}
    else
      {:ok, _} -> {:error, :missing_topic_key}
      error -> error
    end
  end

  @doc """
  Proposes topic→topic edges between `new_topic` (a `%Node{}`) and
  `existing_topics` (list of `%Node{}`).

  Returns `{:ok, [edge_map]}` where each map has keys matching the
  `Topics.create_topic_edges/3` contract.
  """
  @spec extract_topic_edges(Xwa.Graph.Node.t(), [Xwa.Graph.Node.t()]) ::
          {:ok, [map()]} | {:error, term()}
  def extract_topic_edges(_new_topic, []), do: {:ok, []}

  def extract_topic_edges(new_topic, existing_topics) do
    template = edge_prompt_template()

    existing_lines =
      existing_topics
      |> Enum.map(fn t -> "- id: #{t.id}  label: #{t.content}" end)
      |> Enum.join("\n")

    prompt =
      template
      |> String.replace("{{new_topic}}", new_topic.content)
      |> String.replace("{{new_topic_id}}", new_topic.id)
      |> String.replace("{{existing_topics}}", existing_lines)

    with {:ok, raw, _usage} <- call_claude(prompt),
         {:ok, edges} when is_list(edges) <- Jason.decode(extract_json(raw)) do
      valid =
        Enum.flat_map(edges, fn e ->
          from = e["from_node_id"]
          to = e["to_node_id"]
          type = e["type"]

          if is_binary(from) and is_binary(to) and is_binary(type) and
               Enum.any?(existing_topics, &(&1.id == to)) do
            [%{
              from_node_id: from,
              to_node_id: to,
              type: type,
              label: e["label"] || "",
              confidence: (e["confidence"] || 0.7) * 1.0,
              certainty: e["certainty"] || "dashed",
              importance: (e["importance"] || 0.5) * 1.0
            }]
          else
            []
          end
        end)

      {:ok, valid}
    else
      {:ok, _} -> {:ok, []}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  @max_retries 2
  @retry_base_delay_ms 2_000

  defp call_claude(prompt) do
    api_key =
      Application.get_env(:xwa, :anthropic_api_key) ||
        System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      {:error, :anthropic_api_key_not_configured}
    else
      call_claude_with_retry(prompt, api_key, 0)
    end
  end

  defp call_claude_with_retry(prompt, api_key, attempt) do
    body = %{
      model: model(),
      max_tokens: 512,
      messages: [%{role: "user", content: prompt}]
    }

    result =
      Req.post("https://api.anthropic.com/v1/messages",
        json: body,
        headers: [
          {"x-api-key", api_key},
          {"anthropic-version", "2023-06-01"}
        ],
        receive_timeout: 60_000
      )

    case result do
      {:ok, %{status: 200, body: resp_body}} ->
        usage = %{
          input_tokens: get_in(resp_body, ["usage", "input_tokens"]),
          output_tokens: get_in(resp_body, ["usage", "output_tokens"]),
          model: resp_body["model"] || model()
        }

        case resp_body do
          %{"content" => [%{"text" => text} | _]} -> {:ok, text, usage}
          _ -> {:error, {:unexpected_response, resp_body}}
        end

      {:ok, %{status: 529}} when attempt < @max_retries ->
        delay = @retry_base_delay_ms * :math.pow(2, attempt) |> round()
        Process.sleep(delay)
        call_claude_with_retry(prompt, api_key, attempt + 1)

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, %Req.TransportError{reason: reason}}
      when reason in [:timeout, :closed, :econnreset] and attempt < @max_retries ->
        delay = @retry_base_delay_ms * :math.pow(2, attempt) |> round()
        Process.sleep(delay)
        call_claude_with_retry(prompt, api_key, attempt + 1)

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp extract_json(text) do
    trimmed = String.trim(text)

    cond do
      m = Regex.run(~r/```(?:json)?\s*([\s\S]*?)```/m, trimmed, capture: :all_but_first) ->
        String.trim(hd(m))

      m = Regex.run(~r/```(?:json)?\s*([\s\S]+)/m, trimmed, capture: :all_but_first) ->
        String.trim(hd(m))

      true ->
        trimmed
    end
  end

  defp topic_prompt_template do
    path = Application.app_dir(:xwa, "priv/prompts/topic_extraction.md")

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> File.read!(Path.join([:code.priv_dir(:xwa), "prompts/topic_extraction.md"]))
    end
  end

  defp edge_prompt_template do
    path = Application.app_dir(:xwa, "priv/prompts/topic_edge_extraction.md")

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> File.read!(Path.join([:code.priv_dir(:xwa), "prompts/topic_edge_extraction.md"]))
    end
  end

  defp model do
    Application.get_env(:xwa, :claude_topic_model, "claude-haiku-4-5-20251001")
  end
end
