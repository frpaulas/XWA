defmodule Xwa.Graph.FocusScorer do
  @moduledoc """
  Scores graph nodes against a user intent using Claude and returns the top 3
  most relevant node IDs.

  ## Usage

      node_summaries = [%{id: "uuid1", summary: "..."}, ...]
      {:ok, ["uuid1", "uuid2", "uuid3"]} = FocusScorer.score("working on Q3 financials", node_summaries)
  """

  @doc """
  Given a user intent `prompt` and a list of `%{id, summary}` maps,
  returns `{:ok, [id1, id2, id3]}` with the top 3 most relevant node IDs,
  or `{:error, reason}`.
  """
  @spec score(String.t(), [%{id: String.t(), summary: String.t()}]) ::
          {:ok, [String.t()]} | {:error, term()}
  def score(_prompt, []), do: {:ok, []}

  def score(prompt, nodes) when is_binary(prompt) and is_list(nodes) do
    with {:ok, message} <- build_prompt(prompt, nodes),
         {:ok, raw} <- call_claude(message),
         {:ok, ids} <- parse_response(raw) do
      {:ok, ids}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_prompt(prompt, nodes) do
    node_lines =
      nodes
      |> Enum.map(fn %{id: id, summary: summary} ->
        "#{id}: #{summary}"
      end)
      |> Enum.join("\n")

    message = """
    You are helping find relevant starting points in a knowledge graph.

    The user is working on: "#{prompt}"

    Below are claims (nodes) with their IDs and summaries. Return the IDs of the 3 most
    relevant claims as a JSON object. If there are fewer than 3 nodes, return all of them.

    Nodes:
    #{node_lines}

    Respond with ONLY valid JSON: {"top_node_ids": ["id1", "id2", "id3"]}
    """

    {:ok, message}
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
        max_tokens: 256,
        messages: [%{role: "user", content: prompt}]
      }

      case Req.post("https://api.anthropic.com/v1/messages",
             json: body,
             headers: [
               {"x-api-key", api_key},
               {"anthropic-version", "2023-06-01"}
             ],
             receive_timeout: 30_000
           ) do
        {:ok, %{status: 200, body: resp_body}} ->
          case resp_body do
            %{"content" => [%{"text" => text} | _]} -> {:ok, text}
            other -> {:error, {:unexpected_response, other}}
          end

        {:ok, %{status: status, body: resp_body}} ->
          {:error, {:api_error, status, resp_body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end
  end

  defp parse_response(raw) do
    json_str =
      case Regex.run(~r/```(?:json)?\s*([\s\S]*?)```/m, raw, capture: :all_but_first) do
        [json] -> String.trim(json)
        nil -> String.trim(raw)
      end

    with {:ok, %{"top_node_ids" => ids}} when is_list(ids) <- Jason.decode(json_str) do
      {:ok, Enum.filter(ids, &is_binary/1)}
    else
      {:ok, _} -> {:error, :missing_top_node_ids_key}
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  defp model do
    Application.get_env(:xwa, :claude_focus_model,
      Application.get_env(:xwa, :claude_model, "claude-haiku-4-5-20251001"))
  end
end
