defmodule Mix.Tasks.AssignThemes do
  @moduledoc """
  Collapses topic nodes into broad themes by calling Claude.

  Step 1 — proposes 15–20 themes from all existing topic labels.
  Step 2 — classifies each topic into one of those themes (batched).
  Step 3 — writes a `theme` property to each topic node.

  ## Usage

      mix assign_themes              # propose themes only (dry run)
      mix assign_themes --apply      # propose + classify + write
  """

  use Mix.Task
  require Logger

  alias Xwa.Graph

  @shortdoc "Collapse topic nodes into broad themes via Claude"

  @batch_size 80
  @max_retries 2
  @retry_base_ms 2_000

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _} = OptionParser.parse!(args, strict: [apply: :boolean])
    apply? = Keyword.get(opts, :apply, false)

    Mix.shell().info("Loading topic nodes...")

    {:ok, rows} =
      Graph.query("MATCH (n:Claim {node_type: 'topic'}) RETURN n", %{})

    topics = Enum.map(rows, fn %{"n" => bolt} -> Xwa.Graph.Node.from_bolt(bolt) end)
    Mix.shell().info("Found #{length(topics)} topics.")

    if length(topics) == 0 do
      Mix.shell().info("Nothing to do.")
    else
      labels = Enum.map(topics, & &1.content)

      Mix.shell().info("Asking Claude to propose themes...")

      case propose_themes(labels) do
        {:ok, themes} ->
          Mix.shell().info("\nProposed #{length(themes)} themes:")
          Enum.each(themes, fn t -> Mix.shell().info("  - #{t}") end)

          if apply? do
            Mix.shell().info("\nClassifying #{length(topics)} topics in batches of #{@batch_size}...")
            assignments = classify_all(topics, themes)

            Mix.shell().info("Writing theme assignments to graph...")

            Enum.each(assignments, fn {topic_id, theme} ->
              Graph.run(
                "MATCH (n:Claim {id: $id}) SET n.theme = $theme",
                %{id: topic_id, theme: theme}
              )
            end)

            dist =
              assignments
              |> Enum.group_by(fn {_, t} -> t end)
              |> Enum.map(fn {t, xs} -> {t, length(xs)} end)
              |> Enum.sort_by(fn {_, c} -> -c end)

            Mix.shell().info("\nTheme distribution (topics → theme):")
            Enum.each(dist, fn {theme, count} ->
              Mix.shell().info("  #{String.pad_leading(to_string(count), 3)}  #{theme}")
            end)

            unassigned = length(topics) - length(assignments)
            if unassigned > 0 do
              Logger.warning("[AssignThemes] #{unassigned} topics could not be classified")
            end

            Mix.shell().info("\nDone.")
          else
            Mix.shell().info("\nDry run — pass --apply to classify and write.")
          end

        {:error, reason} ->
          Mix.shell().error("Failed to propose themes: #{inspect(reason)}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Theme proposal
  # ---------------------------------------------------------------------------

  defp propose_themes(labels) do
    label_list = labels |> Enum.uniq() |> Enum.join("\n")

    prompt = """
    You are building a navigation taxonomy for a knowledge graph of US Congressional hearing testimony.

    Below are topic labels extracted from individual witness claims. Propose 15–20 broad themes that together cover all of them. Each theme should be a short noun phrase (2–4 words) that could meaningfully group 20–80 of the topics below.

    Rules:
    - 15–20 themes total, no more
    - Each theme is a 2–4 word noun phrase
    - Themes must be mutually distinct — no overlap
    - Every topic below should fit into exactly one theme

    Topic labels:
    #{label_list}

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

  defp classify_all(topics, themes) do
    theme_list =
      themes
      |> Enum.with_index(1)
      |> Enum.map(fn {t, i} -> "#{i}. #{t}" end)
      |> Enum.join("\n")

    # Index topics so Claude returns numbers we can map back to IDs
    indexed = Enum.with_index(topics, 1)
    index_to_id = Map.new(indexed, fn {t, i} -> {i, t.id} end)

    indexed
    |> Enum.chunk_every(@batch_size)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {batch, idx} ->
      total_batches = ceil(length(topics) / @batch_size)
      Mix.shell().info("  Batch #{idx}/#{total_batches}...")

      case classify_batch(batch, theme_list, themes, index_to_id) do
        {:ok, pairs} -> pairs
        {:error, reason} ->
          Logger.warning("[AssignThemes] Batch #{idx} failed: #{inspect(reason)}")
          []
      end
    end)
  end

  defp classify_batch(indexed_topics, theme_list, valid_themes, index_to_id) do
    topic_lines =
      indexed_topics
      |> Enum.map(fn {t, i} -> "#{i}. #{t.content}" end)
      |> Enum.join("\n")

    prompt = """
    Classify each numbered topic into exactly one of the numbered themes below.

    Themes:
    #{theme_list}

    Topics:
    #{topic_lines}

    Respond with JSON only — an object mapping each topic number (as a string) to its theme name (exact string from the list above):
    ```json
    {"1": "Theme Name", "2": "Theme Name", ...}
    ```
    """

    with {:ok, raw, _usage} <- call_claude(prompt, 2048),
         {:ok, map} when is_map(map) <- Jason.decode(extract_json(raw)) do
      pairs =
        Enum.flat_map(map, fn {num_str, theme} ->
          with {num, ""} <- Integer.parse(num_str),
               topic_id when not is_nil(topic_id) <- Map.get(index_to_id, num),
               matched_theme <- match_theme(theme, valid_themes),
               true <- not is_nil(matched_theme) do
            [{topic_id, matched_theme}]
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

  defp match_theme(theme, valid_themes) do
    theme_str = to_string(theme)
    Enum.find(valid_themes, fn t ->
      t == theme_str or String.downcase(t) == String.downcase(theme_str)
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

      {:ok, %{status: s}} when s in [529, 529] and attempt < @max_retries ->
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
