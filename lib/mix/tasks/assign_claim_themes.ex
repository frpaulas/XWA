defmodule Mix.Tasks.AssignClaimThemes do
  @moduledoc """
  Classifies each claim in a graph directly into a broad theme.

  Unlike `assign_themes` (which operates on topic nodes as intermediaries),
  this task classifies claims directly, storing `theme` and `theme_confidence`
  on each claim node.

  ## Steps

  1. Load all claim nodes for the graph.
  2. Sample up to 200 claims and ask Claude to propose 15–20 themes.
  3. Classify every claim in batches (80/batch), storing:
     - `theme` — exact theme name, or "unclassified" if confidence < 0.6
     - `theme_confidence` — float 0.0–1.0

  ## Usage

      mix assign_claim_themes --graph-id UUID              # propose + classify + write
      mix assign_claim_themes --graph-id UUID --dry-run    # propose themes only, no writes
      mix assign_claim_themes --graph-id UUID --skip-existing  # skip already-classified claims
  """

  use Mix.Task
  require Logger

  alias Xwa.Graph
  alias Xwa.Graph.Nodes

  @shortdoc "Classify claims directly into broad themes"

  @sample_size 200
  @batch_size 80
  @max_retries 2
  @retry_base_ms 2_000

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} =
      OptionParser.parse!(args,
        strict: [graph_id: :string, dry_run: :boolean, skip_existing: :boolean]
      )

    graph_id = Keyword.fetch!(opts, :graph_id)
    dry_run? = Keyword.get(opts, :dry_run, false)
    skip_existing? = Keyword.get(opts, :skip_existing, false)

    Mix.shell().info("Loading claims for graph #{graph_id}...")

    {:ok, all_claims} = load_claims(graph_id, skip_existing?)
    Mix.shell().info("Found #{length(all_claims)} claims#{if skip_existing?, do: " (unclassified)", else: ""}.")

    if all_claims == [] do
      Mix.shell().info("Nothing to do.")
    else
      sample = Enum.take(Enum.shuffle(all_claims), @sample_size)
      Mix.shell().info("Proposing themes from #{length(sample)} sampled claims...")

      case propose_themes(sample) do
        {:ok, themes} ->
          Mix.shell().info("\nProposed #{length(themes)} themes:")
          Enum.each(themes, fn t -> Mix.shell().info("  - #{t}") end)

          if dry_run? do
            Mix.shell().info("\nDry run — omit --dry-run to classify and write.")
          else
            Mix.shell().info("\nClassifying #{length(all_claims)} claims in batches of #{@batch_size}...")
            {assignments, unclassified_count} = classify_all(all_claims, themes)

            Mix.shell().info("Writing theme assignments...")
            Enum.each(assignments, fn {claim_id, theme, confidence} ->
              Nodes.set_theme(claim_id, theme, confidence)
            end)

            dist =
              assignments
              |> Enum.group_by(fn {_, t, _} -> t end)
              |> Enum.map(fn {t, xs} -> {t, length(xs)} end)
              |> Enum.sort_by(fn {_, c} -> -c end)

            Mix.shell().info("\nTheme distribution:")
            Enum.each(dist, fn {theme, count} ->
              Mix.shell().info("  #{String.pad_leading(to_string(count), 4)}  #{theme}")
            end)

            if unclassified_count > 0 do
              pct = Float.round(unclassified_count / length(all_claims) * 100, 1)
              Mix.shell().info("\nWarning: #{unclassified_count} claims (#{pct}%) were unclassified (confidence < 0.6)")
            end

            Mix.shell().info("\nDone.")
          end

        {:error, reason} ->
          Mix.shell().error("Failed to propose themes: #{inspect(reason)}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_claims(graph_id, skip_existing?) do
    filter = if skip_existing?, do: "AND n.theme IS NULL", else: ""

    cypher = """
    MATCH (n:Claim {graph_id: $graph_id})
    WHERE n.node_type <> 'topic' AND n.content IS NOT NULL #{filter}
    RETURN n.id AS id, coalesce(n.summary, n.content) AS text
    """

    case Graph.query(cypher, %{graph_id: graph_id}) do
      {:ok, rows} ->
        claims =
          Enum.flat_map(rows, fn %{"id" => id, "text" => text} ->
            if is_binary(text) and String.trim(text) != "", do: [{id, text}], else: []
          end)
        {:ok, claims}

      error ->
        error
    end
  end

  # ---------------------------------------------------------------------------
  # Theme proposal
  # ---------------------------------------------------------------------------

  defp propose_themes(sample) do
    texts =
      sample
      |> Enum.map(fn {_id, text} -> String.slice(text, 0, 200) end)
      |> Enum.join("\n---\n")

    prompt = """
    You are building a navigation taxonomy for a knowledge graph of US Congressional hearing testimony.

    Below are #{length(sample)} claim summaries from a single graph. Propose 15–20 broad themes that together cover all of them. Each theme should be a short noun phrase (2–4 words) suitable for grouping 20–80 claims.

    Rules:
    - 15–20 themes total, no more
    - Each is a 2–4 word noun phrase
    - Themes must be mutually distinct — no overlap
    - Every claim below should fit cleanly into exactly one theme

    Claims (sample):
    #{texts}

    Respond with JSON only:
    ```json
    {"themes": ["theme 1", "theme 2", ...]}
    ```
    """

    with {:ok, raw, _usage} <- call_claude(prompt, 1024),
         {:ok, %{"themes" => themes}} when is_list(themes) <- Jason.decode(extract_json(raw)) do
      {:ok, themes}
    else
      {:ok, _} -> {:error, :unexpected_shape}
      error -> error
    end
  end

  # ---------------------------------------------------------------------------
  # Batch classification
  # ---------------------------------------------------------------------------

  defp classify_all(claims, themes) do
    theme_list =
      themes
      |> Enum.with_index(1)
      |> Enum.map(fn {t, i} -> "#{i}. #{t}" end)
      |> Enum.join("\n")

    indexed = Enum.with_index(claims, 1)
    index_map = Map.new(indexed, fn {{id, _text}, i} -> {i, id} end)

    total_batches = ceil(length(claims) / @batch_size)

    {assignments, unclassified} =
      indexed
      |> Enum.chunk_every(@batch_size)
      |> Enum.with_index(1)
      |> Enum.reduce({[], 0}, fn {batch, batch_idx}, {acc, unclass_acc} ->
        Mix.shell().info("  Batch #{batch_idx}/#{total_batches}...")

        case classify_batch(batch, theme_list, themes, index_map) do
          {:ok, pairs} ->
            new_unclass = Enum.count(pairs, fn {_, t, _} -> t == "unclassified" end)
            {acc ++ pairs, unclass_acc + new_unclass}

          {:error, reason} ->
            Logger.warning("[AssignClaimThemes] Batch #{batch_idx} failed: #{inspect(reason)}")
            {acc, unclass_acc}
        end
      end)

    {assignments, unclassified}
  end

  defp classify_batch(indexed_claims, theme_list, valid_themes, index_map) do
    claim_lines =
      indexed_claims
      |> Enum.map(fn {{_id, text}, i} -> "#{i}. #{String.slice(text, 0, 200)}" end)
      |> Enum.join("\n")

    prompt = """
    Classify each numbered claim into exactly one of the numbered themes. Also rate your confidence (1–10).

    Themes:
    #{theme_list}

    Claims:
    #{claim_lines}

    Respond with JSON only — an object mapping each claim number (string) to {theme, confidence}:
    ```json
    {"1": {"theme": "exact theme name", "confidence": 8}, "2": {...}, ...}
    ```

    If no theme fits well, set confidence to 1–5 and theme to "unclassified".
    """

    with {:ok, raw, _usage} <- call_claude(prompt, 4096),
         {:ok, map} when is_map(map) <- Jason.decode(extract_json(raw)) do
      pairs =
        Enum.flat_map(map, fn {num_str, entry} ->
          with {num, ""} <- Integer.parse(num_str),
               claim_id when not is_nil(claim_id) <- Map.get(index_map, num),
               %{"theme" => theme_raw, "confidence" => conf_raw} <- entry do
            confidence = conf_raw / 10.0
            theme =
              if confidence < 0.6 do
                "unclassified"
              else
                match_theme(theme_raw, valid_themes) || "unclassified"
              end
            [{claim_id, theme, confidence}]
          else
            _ -> []
          end
        end)

      {:ok, pairs}
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
        receive_timeout: 60_000
      )

    case result do
      {:ok, %{status: 200, body: %{"content" => [%{"text" => text} | _]} = resp}} ->
        usage = %{
          input_tokens: get_in(resp, ["usage", "input_tokens"]),
          output_tokens: get_in(resp, ["usage", "output_tokens"])
        }
        {:ok, text, usage}

      {:ok, %{status: 529}} when attempt < @max_retries ->
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
