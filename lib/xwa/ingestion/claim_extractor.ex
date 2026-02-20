defmodule Xwa.Ingestion.ClaimExtractor do
  @moduledoc """
  Extracts claims from document text by calling the Claude API with the
  claim extraction prompt.

  Returns a list of `Xwa.Graph.Node` structs ready for insertion into
  Memgraph. Each node is pre-populated with all fields from the LLM
  response plus provenance fields from the calling context.

  ## Usage

      {:ok, nodes} = ClaimExtractor.extract(text, %{
        document_id: doc.id,
        corpus_layer: doc.corpus_layer,
        source_type:  doc.source_type,
        document_date: doc.document_date,
        created_by:   user_id
      })
  """

  alias Xwa.Graph.Node

  @prompt_path Path.join(:code.priv_dir(:xwa), "prompts/claim_extraction.md")
  @external_resource @prompt_path

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Extracts claims from `text` using the Claude API.

  `context` map keys:
  - `:document_id`   — UUID of the source document (required)
  - `:corpus_layer`  — "self_description" | "internal_record" | "external_context"
  - `:source_type`   — "aspirational" | "operational" | "external"
  - `:document_date` — Date struct or ISO 8601 string; falls back to "unknown"
  - `:created_by`    — UUID of the user who uploaded the document

  Returns `{:ok, [%Node{}]}` or `{:error, reason}`.
  """
  @spec extract(String.t(), map()) :: {:ok, [Node.t()]} | {:error, term()}
  def extract(text, context) when is_binary(text) and is_map(context) do
    with {:ok, prompt} <- build_prompt(text, context),
         {:ok, raw_json} <- call_claude(prompt),
         {:ok, nodes} <- parse_response(raw_json, context) do
      {:ok, nodes}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_prompt(text, context) do
    template = prompt_template()

    corpus_layer = Map.get(context, :corpus_layer) || "unknown"
    source_type = Map.get(context, :source_type) || "unknown"

    document_date =
      case Map.get(context, :document_date) do
        %Date{} = d -> Date.to_iso8601(d)
        s when is_binary(s) -> s
        _ -> "unknown"
      end

    prompt =
      template
      |> String.replace("{{corpus_layer}}", corpus_layer)
      |> String.replace("{{source_type}}", source_type)
      |> String.replace("{{document_date}}", document_date)
      |> String.replace("{{document_text}}", text)

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
        max_tokens: 8192,
        messages: [%{role: "user", content: prompt}]
      }

      case Req.post("https://api.anthropic.com/v1/messages",
             json: body,
             headers: [
               {"x-api-key", api_key},
               {"anthropic-version", "2023-06-01"}
             ],
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200, body: body}} ->
          extract_text_from_response(body)

        {:ok, %{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end
  end

  defp extract_text_from_response(%{"content" => [%{"text" => text} | _]}), do: {:ok, text}
  defp extract_text_from_response(body), do: {:error, {:unexpected_response, body}}

  defp parse_response(raw, context) do
    json_str = extract_json(raw)

    with {:ok, %{"claims" => claims}} when is_list(claims) <- Jason.decode(json_str) do
      nodes =
        claims
        |> Enum.map(&claim_to_node_attrs(&1, context))
        |> Enum.flat_map(fn attrs ->
          case Node.new(attrs) do
            {:ok, node} -> [node]
            {:error, _} -> []
          end
        end)

      {:ok, nodes}
    else
      {:ok, _} -> {:error, :missing_claims_key}
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  # Claude sometimes wraps JSON in a ```json ... ``` fence — strip it.
  defp extract_json(text) do
    case Regex.run(~r/```(?:json)?\s*([\s\S]*?)```/m, text, capture: :all_but_first) do
      [json] -> String.trim(json)
      nil -> String.trim(text)
    end
  end

  defp claim_to_node_attrs(claim, context) do
    %{
      content: claim["content"],
      summary: claim["summary"],
      type: claim["type"],
      confidence: claim["confidence"] || 1.0,
      tags: claim["tags"] || [],
      source_document_id: Map.get(context, :document_id),
      source_type: Map.get(context, :source_type),
      corpus_layer: Map.get(context, :corpus_layer),
      created_by: Map.get(context, :created_by),
      asserted_at: parse_date(claim["asserted_at"]),
      ai_inferred: true,
      human_validated: false
    }
  end

  defp parse_date(nil), do: nil

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp prompt_template do
    # Load from priv/prompts at runtime so it can be updated without recompile.
    path =
      Application.app_dir(:xwa, "priv/prompts/claim_extraction.md")

    case File.read(path) do
      {:ok, content} ->
        content

      {:error, _} ->
        # Fallback: read relative to project root in dev
        File.read!(Path.join([:code.priv_dir(:xwa), "../..", "prompts", "claim_extraction.md"]))
    end
  end

  defp model do
    Application.get_env(:xwa, :claude_model, "claude-sonnet-4-6")
  end
end
