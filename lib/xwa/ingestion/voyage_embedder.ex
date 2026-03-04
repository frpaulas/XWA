defmodule Xwa.Ingestion.VoyageEmbedder do
  @moduledoc """
  Generates embeddings via the Voyage AI API (voyage-3 model).

  Voyage AI is Anthropic's recommended embedding provider. Embeddings are
  stored on Claim nodes and used for semantic similarity during graph merges,
  replacing expensive per-pair LLM calls.

  ## Pricing (voyage-3, as of early 2026)
    - $0.06 per 1M tokens
    - Typical claim summary: ~20-40 tokens → ~$0.000002 per node

  ## Usage

      {:ok, embeddings, usage} = VoyageEmbedder.embed(["text one", "text two"])
      # embeddings: [[0.1, 0.2, ...], [0.3, 0.4, ...]]  — 1024-dim each
      # usage: %{total_tokens: 12, cost_usd: Decimal.new("0.00000072"), model: "voyage-3"}

  For large batches, use `embed_many/2` which handles Voyage's 128-text-per-request limit.
  """

  require Logger

  @model "voyage-3"
  @max_batch_size 128
  @voyage_url "https://api.voyageai.com/v1/embeddings"

  # $0.06 per 1M tokens = $0.00000006 per token
  @cost_per_token Decimal.new("0.00000006")

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Embeds a list of texts. Automatically batches if len(texts) > 128.

  Returns `{:ok, embeddings, usage}` where:
    - `embeddings` is a list of float vectors in the same order as `texts`
    - `usage` is `%{total_tokens: integer, cost_usd: Decimal.t(), model: String.t()}`

  Returns `{:error, reason}` on failure.
  """
  @spec embed([String.t()]) :: {:ok, [[float()]], map()} | {:error, term()}
  def embed([]), do: {:ok, [], %{total_tokens: 0, cost_usd: Decimal.new("0"), model: @model}}

  def embed(texts) when is_list(texts) do
    texts
    |> Enum.chunk_every(@max_batch_size)
    |> Enum.reduce_while({:ok, [], 0}, fn batch, {:ok, acc_embeddings, acc_tokens} ->
      case embed_batch(batch) do
        {:ok, embeddings, tokens} ->
          {:cont, {:ok, acc_embeddings ++ embeddings, acc_tokens + tokens}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, embeddings, total_tokens} ->
        cost = Decimal.mult(Decimal.new(total_tokens), @cost_per_token)
        {:ok, embeddings, %{total_tokens: total_tokens, cost_usd: cost, model: @model}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Embeds a list of `{id, text}` tuples and returns `{id, embedding}` pairs.

  Preserves ordering. Skips nil/empty texts, returning no embedding for them.

      {:ok, pairs, usage} = VoyageEmbedder.embed_keyed([{"uuid-1", "text..."}, ...])
      # pairs: [{"uuid-1", [0.1, ...]}, ...]
  """
  @spec embed_keyed([{String.t(), String.t()}]) ::
          {:ok, [{String.t(), [float()]}], map()} | {:error, term()}
  def embed_keyed([]), do: {:ok, [], %{total_tokens: 0, cost_usd: Decimal.new("0"), model: @model}}

  def embed_keyed(pairs) when is_list(pairs) do
    {ids, texts} =
      pairs
      |> Enum.filter(fn {_id, text} -> is_binary(text) and text != "" end)
      |> Enum.unzip()

    case embed(texts) do
      {:ok, embeddings, usage} ->
        keyed = Enum.zip(ids, embeddings)
        {:ok, keyed, usage}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp embed_batch(texts) do
    api_key =
      Application.get_env(:xwa, :voyage_api_key) ||
        System.get_env("VOYAGE_API_KEY")

    if is_nil(api_key) do
      {:error, :voyage_api_key_not_configured}
    else
      body = %{model: @model, input: texts}

      case Req.post(@voyage_url,
             json: body,
             headers: [{"Authorization", "Bearer #{api_key}"}],
             receive_timeout: 60_000
           ) do
        {:ok, %{status: 200, body: resp}} ->
          embeddings =
            resp["data"]
            |> Enum.sort_by(& &1["index"])
            |> Enum.map(& &1["embedding"])

          tokens = get_in(resp, ["usage", "total_tokens"]) || 0
          {:ok, embeddings, tokens}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("[VoyageEmbedder] API error #{status}: #{inspect(body)}")
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          Logger.warning("[VoyageEmbedder] HTTP error: #{inspect(reason)}")
          {:error, {:http_error, reason}}
      end
    end
  end
end
