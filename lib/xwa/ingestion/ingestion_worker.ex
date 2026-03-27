defmodule Xwa.Ingestion.IngestionWorker do
  @moduledoc """
  Orchestrates the full ingestion pipeline for a single document.

  Pipeline steps:
  1. Load document + content from Postgres
  2. Decrypt content if needed
  3. Extract claims via ClaimExtractor (Claude API) — logs ExtractionRun
  4. For each claim:
     a. Insert node into Memgraph
     b. Embed node inline via Voyage AI (single call) — stores embedding immediately
     c. Fetch neighbourhood: rank all existing embedded nodes by cosine similarity,
        take top @neighbourhood_size as candidates for edge extraction
     d. Extract edges via EdgeExtractor (Claude API) — logs ExtractionRun
     e. Insert edges into Memgraph
  5. Embed any remaining nodes without embeddings via Voyage AI — logs ExtractionRun
  6. Advance document ingestion_status to "complete" (or "failed")

  ## Usage

  Run inline (blocks until done — suitable for dev/test):

      IngestionWorker.run(document_id, user_id, graph_id)

  Run in a spawned task (non-blocking — for production use from LiveView):

      IngestionWorker.run_async(document_id, user_id, graph_id)
  """

  require Logger

  alias Xwa.Documents
  alias Xwa.Graphs
  alias Xwa.Graph.{Nodes, Edges, Topics, VectorMath}
  alias Xwa.Ingestion.{ClaimExtractor, DocumentSegmenter, EdgeExtractor, ExtractionRuns, NliGate, TextExtractor, ThemeClassifier, TopicExtractor, VoyageEmbedder}

  # Cosine pre-filter pool size — fetched before NLI gate
  @cosine_pool_size 50
  # Final neighbourhood size passed to Claude after NLI gate (or cosine fallback)
  @neighbourhood_size 20
  @prompt_version "v1"

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Runs the full ingestion pipeline synchronously.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec run(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def run(document_id, requesting_user_id, graph_id) do
    Logger.info("[Ingestion] Starting ingestion for document #{document_id}")

    org_id = resolve_org_id(graph_id)

    result =
      with {:ok, doc, text} <- load_content(document_id, requesting_user_id),
           :ok <- advance_status(doc, "processing"),
           {:ok, nodes} <- extract_all_claims(doc, text, requesting_user_id, graph_id),
           :ok <- broadcast_progress(graph_id, document_id, length(nodes), 0),
           {:ok, edge_count} <- insert_nodes_and_edges(nodes, doc, requesting_user_id, graph_id, org_id),
           :ok <- broadcast_progress(graph_id, document_id, length(nodes), edge_count),
           :ok <- insert_wiki_links(text, nodes, doc, requesting_user_id, graph_id),
           :ok <- embed_nodes(nodes, doc, graph_id) do
        :ok
      end

    case result do
      :ok ->
        doc = Documents.get_document!(document_id)
        Documents.update_ingestion_status(doc, "complete")
        Phoenix.PubSub.broadcast(Xwa.PubSub, "graph:#{graph_id}", {:ingestion_complete, document_id})
        Logger.info("[Ingestion] Completed ingestion for document #{document_id}")
        start_next_pending(requesting_user_id, graph_id)
        :ok

      {:error, reason} ->
        Logger.error("[Ingestion] Failed ingestion for document #{document_id}: #{inspect(reason)}")

        case Documents.get_document(document_id) do
          nil -> :ok
          doc -> Documents.update_ingestion_status(doc, "failed", error: inspect(reason))
        end

        Phoenix.PubSub.broadcast(Xwa.PubSub, "graph:#{graph_id}", {:ingestion_failed, document_id})
        start_next_pending(requesting_user_id, graph_id)
        {:error, reason}
    end
  end

  defp broadcast_progress(graph_id, document_id, claims, edges) do
    Phoenix.PubSub.broadcast(Xwa.PubSub, "graph:#{graph_id}",
      {:ingestion_progress, document_id, %{claims: claims, edges: edges}})
    :ok
  end

  defp start_next_pending(requesting_user_id, graph_id) do
    case Documents.next_pending(graph_id) do
      nil ->
        :ok

      doc ->
        Logger.info("[Ingestion] Starting next pending document #{doc.id} for graph #{graph_id}")
        start_task(doc.id, doc.created_by || requesting_user_id, graph_id)
    end
  end

  @doc """
  Spawns the ingestion pipeline in a supervised Task if no other document in
  the graph is currently processing. If one is, the document stays pending and
  will be picked up automatically when the active job finishes.

  Returns `{:ok, pid}` when started or `{:ok, :queued}` when deferred.
  """
  @spec run_async(String.t(), String.t(), String.t()) :: {:ok, pid()} | {:ok, :queued}
  def run_async(document_id, requesting_user_id, graph_id) do
    if Documents.any_processing?(graph_id) do
      Logger.info("[Ingestion] Graph #{graph_id} has a document processing — queuing #{document_id}")
      {:ok, :queued}
    else
      start_task(document_id, requesting_user_id, graph_id)
    end
  end

  defp start_task(document_id, requesting_user_id, graph_id) do
    Task.Supervisor.start_child(
      Xwa.TaskSupervisor,
      fn -> run(document_id, requesting_user_id, graph_id) end
    )
  end

  # ---------------------------------------------------------------------------
  # Pipeline steps
  # ---------------------------------------------------------------------------

  defp load_content(document_id, requesting_user_id) do
    doc = Documents.get_document!(document_id)

    case Documents.get_decrypted_content(document_id, requesting_user_id) do
      {:ok, %{extracted_text: text}} when is_binary(text) and text != "" ->
        {:ok, doc, text}

      {:ok, %{content: raw}} when is_binary(raw) ->
        # extracted_text was nil or empty — attempt re-extraction from the stored binary
        Logger.info("[Ingestion] extracted_text missing for #{document_id} — re-extracting from binary")
        ct = doc.content_type || "application/octet-stream"

        case TextExtractor.extract(raw, ct) do
          {:ok, text} when is_binary(text) and text != "" ->
            Documents.update_extracted_text(document_id, text)
            {:ok, doc, text}

          {:ok, _} ->
            {:error, :no_extracted_text}

          {:error, reason} ->
            {:error, {:text_extraction_failed, reason}}
        end

      {:ok, _} ->
        {:error, :no_extracted_text}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp advance_status(doc, status) do
    case Documents.update_ingestion_status(doc, status) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Segments the document if it's a congressional hearing, then extracts claims
  # from each segment in sequence. For all other source types, falls through to
  # a single extraction pass (segment = the whole document text).
  defp extract_all_claims(doc, text, requesting_user_id, graph_id) do
    segments = DocumentSegmenter.segment(text)

    if segments == [] do
      Logger.error("[Ingestion] DocumentSegmenter returned no segments for document #{doc.id} — skipping extraction")
    end

    result =
      Enum.reduce_while(segments, {:ok, []}, fn seg, {:ok, acc} ->
        case extract_claims(doc, seg, requesting_user_id, graph_id) do
          {:ok, nodes} -> {:cont, {:ok, acc ++ nodes}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, nodes} ->
        deduped = dedup_claims(nodes)
        dropped = length(nodes) - length(deduped)
        if dropped > 0, do: Logger.info("[Ingestion] Deduped #{dropped} near-duplicate claim(s) from document #{doc.id}")
        {:ok, deduped}

      error ->
        error
    end
  end

  # Removes near-duplicate claims within a single document run using word-set
  # Jaccard similarity. Keeps the first occurrence when similarity exceeds the
  # threshold. This catches both exact duplicates and paraphrased claims that
  # arise when the same content appears at a segment boundary.
  @jaccard_threshold 0.75

  defp dedup_claims(nodes) do
    {kept, _seen} =
      Enum.reduce(nodes, {[], []}, fn node, {acc, seen_word_sets} ->
        words = content_word_set(node.content)

        if Enum.any?(seen_word_sets, &(jaccard(&1, words) >= @jaccard_threshold)) do
          {acc, seen_word_sets}
        else
          {[node | acc], [words | seen_word_sets]}
        end
      end)

    Enum.reverse(kept)
  end

  defp content_word_set(nil), do: MapSet.new()
  defp content_word_set(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.split(~r/\s+/, trim: true)
    |> MapSet.new()
  end

  defp jaccard(set_a, set_b) do
    intersection = MapSet.intersection(set_a, set_b) |> MapSet.size()
    union = MapSet.union(set_a, set_b) |> MapSet.size()
    if union == 0, do: 1.0, else: intersection / union
  end

  defp extract_claims(doc, %{text: text} = segment, requesting_user_id, graph_id) do
    context = %{
      document_id: doc.id,
      graph_id: graph_id,
      corpus_layer: doc.corpus_layer,
      source_type: doc.source_type,
      document_date: doc.document_date,
      created_by: requesting_user_id,
      # Segment provenance — passed through to the prompt and node metadata
      speaker: Map.get(segment, :speaker),
      segment_type: Map.get(segment, :segment_type),
      from_line: Map.get(segment, :from_line),
      to_line: Map.get(segment, :to_line)
    }

    enriched_text = prepend_speaker_context(text, segment)

    t0 = System.monotonic_time(:millisecond)

    case ClaimExtractor.extract(enriched_text, context) do
      {:ok, nodes, usage} ->
        duration_ms = System.monotonic_time(:millisecond) - t0

        log_run(%{
          run_type: "claim",
          document_id: doc.id,
          graph_id: graph_id,
          status: "ok",
          document_size_bytes: byte_size(text),
          nodes_extracted: length(nodes),
          duration_ms: duration_ms,
          usage: usage
        })

        Logger.info("[Ingestion] Extracted #{length(nodes)} claims from document #{doc.id}")
        {:ok, nodes}

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - t0

        log_run(%{
          run_type: "claim",
          document_id: doc.id,
          graph_id: graph_id,
          status: "error",
          document_size_bytes: byte_size(text),
          duration_ms: duration_ms,
          error_message: inspect(reason),
          usage: %{}
        })

        {:error, {:claim_extraction_failed, reason}}
    end
  end

  defp insert_nodes_and_edges(nodes, doc, requesting_user_id, graph_id, org_id) do
    context = %{
      document_id: doc.id,
      graph_id: graph_id,
      org_id: org_id,
      created_by: requesting_user_id
    }

    Enum.reduce_while(nodes, {:ok, 0}, fn node, {:ok, edge_acc} ->
      case insert_node_with_edges(node, doc, context) do
        {:ok, n_edges} -> {:cont, {:ok, edge_acc + n_edges}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_node_with_edges(node, doc, context) do
    with {:ok, inserted_node} <- Nodes.create(node) do
      node_embedding = embed_node_inline(inserted_node)
      assign_topic_async(inserted_node, context)
      assign_theme_async(inserted_node, context)
      neighbours = fetch_neighbourhood(inserted_node, node_embedding, doc, context.graph_id)

      t0 = System.monotonic_time(:millisecond)

      case EdgeExtractor.extract(inserted_node, neighbours, context) do
        {:ok, edges, usage} ->
          duration_ms = System.monotonic_time(:millisecond) - t0

          unless map_size(usage) == 0 do
            log_run(%{
              run_type: "edge",
              document_id: doc.id,
              graph_id: context.graph_id,
              status: "ok",
              edges_extracted: length(edges),
              duration_ms: duration_ms,
              usage: usage
            })
          end

          insert_edges(edges)
          {:ok, length(edges)}

        {:error, reason} ->
          duration_ms = System.monotonic_time(:millisecond) - t0

          log_run(%{
            run_type: "edge",
            document_id: doc.id,
            graph_id: context.graph_id,
            status: "error",
            duration_ms: duration_ms,
            error_message: inspect(reason),
            usage: %{}
          })

          Logger.warning(
            "[Ingestion] Edge extraction failed for node #{inserted_node.id}: #{inspect(reason)}"
          )

          {:ok, 0}
      end
    end
  end

  defp insert_edges([]), do: :ok

  defp insert_edges(edges) do
    Enum.each(edges, fn edge ->
      case Edges.create(edge) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("[Ingestion] Failed to insert edge: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # WikiLink extraction
  # ---------------------------------------------------------------------------

  @wiki_link_pattern ~r/\[\[([^\[\]]+)\]\]/

  defp insert_wiki_links(text, claim_nodes, doc, requesting_user_id, graph_id) do
    phrases =
      @wiki_link_pattern
      |> Regex.scan(text, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&String.trim/1)
      |> Enum.uniq()

    if phrases == [] do
      :ok
    else
      Logger.info("[Ingestion] Found #{length(phrases)} [[WikiLink]] references in document #{doc.id}")

      context = %{
        source_document_id: doc.id,
        source_type: doc.source_type,
        corpus_layer: doc.corpus_layer,
        created_by: requesting_user_id,
        graph_id: graph_id
      }

      concept_nodes =
        Enum.flat_map(phrases, fn phrase ->
          case Nodes.merge_concept(Map.put(context, :content, phrase)) do
            {:ok, node} -> [node]
            {:error, reason} ->
              Logger.warning("[Ingestion] Failed to merge concept node '#{phrase}': #{inspect(reason)}")
              []
          end
        end)

      Enum.each(claim_nodes, fn claim ->
        Enum.each(concept_nodes, fn concept ->
          edge_attrs = %{
            from_node_id: claim.id,
            to_node_id: concept.id,
            type: "mentions",
            source_document_ids: [doc.id],
            created_by: requesting_user_id,
            ai_inferred: false,
            confidence: 1.0,
            certainty: "solid",
            graph_id: graph_id,
            visibility: "system"
          }

          case Edges.create(edge_attrs) do
            {:ok, _} -> :ok
            {:error, reason} ->
              Logger.warning("[Ingestion] Failed to create mentions edge #{claim.id}->#{concept.id}: #{inspect(reason)}")
          end
        end)
      end)

      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Topic assignment
  # ---------------------------------------------------------------------------

  # Fire-and-forget: extract a topic label and assign the node to it.
  # Runs in a supervised task so a topic API failure doesn't block ingestion.
  defp assign_topic_async(_node, %{org_id: nil}), do: :ok

  defp assign_topic_async(node, context) do
    Task.Supervisor.start_child(Xwa.TaskSupervisor, fn ->
      claim_text = node.summary || node.content

      case TopicExtractor.extract_topic(claim_text) do
        {:ok, topic_label} ->
          case Topics.find_or_create(topic_label, context.org_id, created_by: context.created_by) do
            {:ok, topic_node, :created} ->
              Logger.info("[Ingestion] Created topic '#{topic_label}' for org #{context.org_id}")
              Topics.assign_topic(node.id, topic_node.id, context.graph_id, context.created_by)
              # Propose topic→topic edges for the newly created topic
              case Nodes.list_topics(context.org_id) do
                {:ok, existing} ->
                  others = Enum.reject(existing, &(&1.id == topic_node.id))
                  case TopicExtractor.extract_topic_edges(topic_node, others) do
                    {:ok, edges} ->
                      Topics.create_topic_edges(edges, context.org_id, context.created_by)
                    {:error, reason} ->
                      Logger.warning("[Ingestion] Topic edge extraction failed: #{inspect(reason)}")
                  end
                _ -> :ok
              end

            {:ok, topic_node, :existing} ->
              Topics.assign_topic(node.id, topic_node.id, context.graph_id, context.created_by)

            {:error, reason} ->
              Logger.warning("[Ingestion] Topic find_or_create failed for '#{topic_label}': #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.warning("[Ingestion] Topic extraction failed for node #{node.id}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Theme assignment
  # ---------------------------------------------------------------------------

  # Fire-and-forget: classify the claim against the graph's existing themes.
  # No-ops if no themes have been assigned to the graph yet.
  defp assign_theme_async(node, context) do
    Task.Supervisor.start_child(Xwa.TaskSupervisor, fn ->
      case Nodes.list_distinct_themes(context.graph_id) do
        {:ok, []} ->
          :ok

        {:ok, themes} ->
          claim_text = node.summary || node.content

          case ThemeClassifier.classify(claim_text, themes) do
            {:ok, {theme, confidence}} ->
              Nodes.set_theme(node.id, theme, confidence)

              if theme == "unclassified" do
                Logger.info("[Ingestion] Node #{node.id} did not fit any theme (confidence #{confidence}) — consider regenerating themes")
              end

            {:error, reason} ->
              Logger.warning("[Ingestion] Theme classification failed for node #{node.id}: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.warning("[Ingestion] Failed to load themes for graph #{context.graph_id}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp resolve_org_id(graph_id) do
    case Graphs.get_graph(graph_id) do
      %{organization_id: org_id} -> org_id
      _ -> nil
    end
  end

  # Embeds a single node inline (before batch embed step) so cosine ranking works.
  # Stores the embedding to Memgraph immediately; embed_nodes/3 will skip it.
  defp embed_node_inline(node) do
    text = node.summary || node.content

    case VoyageEmbedder.embed([text]) do
      {:ok, [embedding], _usage} ->
        Nodes.set_embedding(node.id, embedding)
        embedding

      _ ->
        nil
    end
  end

  # With a valid embedding: rank all candidates by cosine similarity, return top N.
  defp fetch_neighbourhood(node, node_embedding, doc, graph_id) when not is_nil(node_embedding) do
    case Nodes.list_embeddings(graph_id) do
      {:ok, []} ->
        fetch_neighbourhood_unranked(node, doc, graph_id)

      {:ok, embedding_pairs} ->
        norm_new = VectorMath.normalize(node_embedding)

        # Fetch a larger cosine pool, then narrow via NLI gate
        top_ids =
          embedding_pairs
          |> Enum.reject(fn {id, _} -> id == node.id end)
          |> Enum.map(fn {id, emb} ->
            score = VectorMath.dot_product(norm_new, VectorMath.normalize(emb))
            {id, score}
          end)
          |> Enum.sort_by(fn {_, score} -> score end, :desc)
          |> Enum.take(@cosine_pool_size)
          |> Enum.map(fn {id, _} -> id end)
          |> MapSet.new()

        layer = doc.corpus_layer || node.corpus_layer

        source =
          if layer do
            case Nodes.list_by_corpus_layer(graph_id, layer) do
              {:ok, nodes} -> nodes
              _ -> []
            end
          else
            case Nodes.list(graph_id) do
              {:ok, nodes} -> nodes
              _ -> []
            end
          end

        cosine_pool =
          source
          |> Enum.reject(&(&1.id == node.id))
          |> Enum.filter(&MapSet.member?(top_ids, &1.id))

        # NLI gate: drop neutral pairs, keep top @neighbourhood_size
        claim_text = node.summary || node.content || ""
        NliGate.filter(claim_text, cosine_pool, keep: @neighbourhood_size)

      _ ->
        fetch_neighbourhood_unranked(node, doc, graph_id)
    end
  end

  # Fallback when no embedding available: original unranked behaviour.
  defp fetch_neighbourhood(node, _node_embedding, doc, graph_id) do
    fetch_neighbourhood_unranked(node, doc, graph_id)
  end

  defp fetch_neighbourhood_unranked(node, doc, graph_id) do
    layer = doc.corpus_layer || node.corpus_layer

    candidates =
      if layer do
        case Nodes.list_by_corpus_layer(graph_id, layer) do
          {:ok, nodes} -> nodes
          _ -> []
        end
      else
        case Nodes.list(graph_id) do
          {:ok, nodes} -> nodes
          _ -> []
        end
      end

    candidates
    |> Enum.reject(&(&1.id == node.id))
    |> Enum.take(@neighbourhood_size)
  end

  # ---------------------------------------------------------------------------
  # Embedding
  # ---------------------------------------------------------------------------

  defp embed_nodes(_nodes, doc, graph_id) do
    # Use list_missing_embeddings so nodes already embedded inline are skipped.
    pairs =
      case Nodes.list_missing_embeddings(graph_id) do
        {:ok, missing} -> missing
        _ -> []
      end

    if pairs == [] do
      Logger.info("[Ingestion] All nodes already embedded for document #{doc.id}")
      :ok
    else
      do_embed_nodes(pairs, doc, graph_id)
    end
  end

  defp do_embed_nodes(pairs, doc, graph_id) do
    t0 = System.monotonic_time(:millisecond)

    case VoyageEmbedder.embed_keyed(pairs) do
      {:ok, keyed_embeddings, usage} ->
        duration_ms = System.monotonic_time(:millisecond) - t0

        Enum.each(keyed_embeddings, fn {id, embedding} ->
          case Nodes.set_embedding(id, embedding) do
            :ok -> :ok
            {:error, reason} ->
              Logger.warning("[Ingestion] Failed to store embedding for node #{id}: #{inspect(reason)}")
          end
        end)

        log_run(%{
          run_type: "embedding",
          document_id: doc.id,
          graph_id: graph_id,
          status: "ok",
          nodes_extracted: length(keyed_embeddings),
          duration_ms: duration_ms,
          usage: %{
            model: usage.model,
            input_tokens: usage.total_tokens,
            output_tokens: 0,
            cost_usd_override: usage.cost_usd
          }
        })

        Logger.info("[Ingestion] Embedded #{length(keyed_embeddings)} nodes for document #{doc.id}")
        :ok

      {:error, :voyage_api_key_not_configured} ->
        Logger.info("[Ingestion] Voyage API key not configured — skipping embedding for document #{doc.id}")
        :ok

      {:error, reason} ->
        duration_ms = System.monotonic_time(:millisecond) - t0

        log_run(%{
          run_type: "embedding",
          document_id: doc.id,
          graph_id: graph_id,
          status: "error",
          duration_ms: duration_ms,
          error_message: inspect(reason),
          usage: %{}
        })

        Logger.warning("[Ingestion] Embedding failed for document #{doc.id}: #{inspect(reason)}")
        # Non-fatal — embeddings can be backfilled later
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Segment text enrichment
  # ---------------------------------------------------------------------------

  # Prepends a compact speaker/provenance header to the segment text so that
  # the claim extractor has attribution context without requiring prompt changes.
  # No-ops when the segment carries no speaker metadata (non-hearing documents).
  defp prepend_speaker_context(text, %{speaker: nil}), do: text
  defp prepend_speaker_context(text, %{speaker: speaker, segment_type: seg_type, from_line: from, to_line: to}) do
    role_label = case speaker[:role] do
      :chair           -> "Committee Chair"
      :ranking_member  -> "Ranking Member"
      :witness         -> "Witness"
      :member          -> "Member of Congress"
      _                -> "Speaker"
    end

    affiliation = if speaker[:affiliation], do: " (#{speaker[:affiliation]})", else: ""

    type_label = case seg_type do
      :opening_statement -> "Opening Statement"
      :witness_statement -> "Witness Testimony"
      :qa_turn           -> "Q&A"
      :dialogue_turn     -> "Statement"
      _                  -> "Statement"
    end

    lines_label = if from && to, do: " [lines #{from}–#{to}]", else: ""

    header = "[#{type_label}#{lines_label} — #{role_label}: #{speaker[:name]}#{affiliation}]"

    "#{header}\n\n#{text}"
  end
  defp prepend_speaker_context(text, _), do: text

  # ---------------------------------------------------------------------------
  # ExtractionRun logging
  # ---------------------------------------------------------------------------

  defp log_run(%{run_type: run_type, usage: usage} = attrs) do
    run_attrs = %{
      run_type: run_type,
      document_id: Map.get(attrs, :document_id),
      graph_id: Map.get(attrs, :graph_id),
      model: Map.get(usage, :model, "unknown"),
      prompt_version: @prompt_version,
      status: Map.get(attrs, :status, "ok"),
      document_size_bytes: Map.get(attrs, :document_size_bytes),
      nodes_extracted: Map.get(attrs, :nodes_extracted),
      edges_extracted: Map.get(attrs, :edges_extracted),
      input_tokens: Map.get(usage, :input_tokens),
      output_tokens: Map.get(usage, :output_tokens),
      cost_usd: Map.get(usage, :cost_usd_override) || compute_cost(run_type, usage),
      latency_ms: Map.get(usage, :latency_ms),
      duration_ms: Map.get(attrs, :duration_ms),
      finish_reason: Map.get(usage, :finish_reason),
      error_message: Map.get(attrs, :error_message)
    }

    case ExtractionRuns.log(run_attrs) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("[Ingestion] Failed to log extraction run: #{inspect(reason)}")
    end
  end

  # Claude pricing as of early 2026 (claude-sonnet-4-6):
  #   Input:  $3.00 / 1M tokens  = $0.000003 per token
  #   Output: $15.00 / 1M tokens = $0.000015 per token
  # Override via config if pricing changes.
  defp compute_cost(_run_type, usage) when map_size(usage) == 0, do: nil
  defp compute_cost(_run_type, %{input_tokens: nil}), do: nil
  defp compute_cost(_run_type, %{output_tokens: nil}), do: nil

  defp compute_cost(_run_type, %{input_tokens: input, output_tokens: output}) do
    input_rate  = Application.get_env(:xwa, :claude_input_cost_per_token,  Decimal.new("0.000003"))
    output_rate = Application.get_env(:xwa, :claude_output_cost_per_token, Decimal.new("0.000015"))

    Decimal.add(
      Decimal.mult(Decimal.new(input),  input_rate),
      Decimal.mult(Decimal.new(output), output_rate)
    )
  end
end
