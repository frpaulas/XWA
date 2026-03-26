defmodule Xwa.Ingestion.ThemeClassifier do
  @moduledoc """
  Classifies a single claim into one of a fixed set of themes, returning the
  matched theme name and a confidence score (0.0–1.0).

  Used both by `mix assign_claim_themes` (batch backfill) and by
  `IngestionWorker` (inline classification of new claims).
  """

  require Logger

  @max_retries 2
  @retry_base_ms 2_000

  @doc """
  Classifies `claim_text` against `themes` (a list of theme name strings).

  Returns `{:ok, {theme, confidence}}` where:
  - `theme` is the exact string from `themes`, or `"unclassified"` if confidence < 0.6
  - `confidence` is 0.0–1.0

  Returns `{:error, reason}` on API failure.
  """
  @spec classify(String.t(), [String.t()]) :: {:ok, {String.t(), float()}} | {:error, term()}
  def classify(claim_text, themes) when is_binary(claim_text) and is_list(themes) do
    theme_list =
      themes
      |> Enum.with_index(1)
      |> Enum.map(fn {t, i} -> "#{i}. #{t}" end)
      |> Enum.join("\n")

    prompt = """
    You are classifying a claim from US Congressional hearing testimony into a broad theme.

    Available themes:
    #{theme_list}

    Claim:
    #{String.slice(claim_text, 0, 800)}

    Respond with JSON only:
    ```json
    {"theme": "exact theme name from the list above", "confidence": 8}
    ```

    Rules:
    - `theme` must be the exact string from the list above
    - `confidence` is 1–10 (10 = perfect fit, 1 = no good match)
    - If no theme fits well (confidence < 6), use "unclassified" as the theme
    """

    with {:ok, raw, _usage} <- call_claude(prompt, 256),
         {:ok, %{"theme" => theme_raw, "confidence" => conf_raw}} <- Jason.decode(extract_json(raw)) do
      confidence = conf_raw / 10.0
      theme = if confidence < 0.6, do: "unclassified", else: match_theme(theme_raw, themes)
      {:ok, {theme || "unclassified", confidence}}
    else
      {:ok, _} -> {:error, :unexpected_shape}
      error -> error
    end
  end

  defp match_theme(theme_raw, valid_themes) do
    Enum.find(valid_themes, fn t ->
      t == theme_raw or String.downcase(t) == String.downcase(theme_raw)
    end)
  end

  # ---------------------------------------------------------------------------
  # Claude API
  # ---------------------------------------------------------------------------

  defp call_claude(prompt, max_tokens) do
    api_key =
      Application.get_env(:xwa, :anthropic_api_key) ||
        System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) do
      {:error, :anthropic_api_key_not_configured}
    else
      call_claude_with_retry(prompt, max_tokens, api_key, 0)
    end
  end

  defp call_claude_with_retry(prompt, max_tokens, api_key, attempt) do
    body = %{
      model: "claude-haiku-4-5-20251001",
      max_tokens: max_tokens,
      messages: [%{role: "user", content: prompt}]
    }

    result =
      Req.post("https://api.anthropic.com/v1/messages",
        json: body,
        headers: [
          {"x-api-key", api_key},
          {"anthropic-version", "2023-06-01"}
        ],
        receive_timeout: 30_000
      )

    case result do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]} = resp}} ->
        usage = %{
          input_tokens: get_in(resp, ["usage", "input_tokens"]),
          output_tokens: get_in(resp, ["usage", "output_tokens"])
        }
        {:ok, text, usage}

      {:ok, %{status: s}} when s in [529] and attempt < @max_retries ->
        Process.sleep(round(@retry_base_ms * :math.pow(2, attempt)))
        call_claude_with_retry(prompt, max_tokens, api_key, attempt + 1)

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, %Req.TransportError{reason: r}}
      when r in [:timeout, :closed, :econnreset] and attempt < @max_retries ->
        Process.sleep(round(@retry_base_ms * :math.pow(2, attempt)))
        call_claude_with_retry(prompt, max_tokens, api_key, attempt + 1)

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
end
