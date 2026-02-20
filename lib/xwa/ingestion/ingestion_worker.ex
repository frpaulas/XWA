defmodule Xwa.Ingestion.IngestionWorker do
  @moduledoc """
  Orchestrates the full ingestion pipeline for a single document.

  Pipeline steps:
  1. Load document + content from Postgres
  2. Decrypt content if needed
  3. Extract claims via ClaimExtractor (Claude API)
  4. For each claim:
     a. Insert node into Memgraph
     b. Fetch semantically relevant existing nodes
     c. Extract edges via EdgeExtractor (Claude API)
     d. Insert edges into Memgraph
  5. Advance document ingestion_status to "complete" (or "failed")

  ## Usage

  Run inline (blocks until done — suitable for dev/test):

      IngestionWorker.run(document_id, user_id)

  Run in a spawned task (non-blocking — for production use from LiveView):

      IngestionWorker.run_async(document_id, user_id)

  ## Semantic neighbourhood

  Edge extraction is only useful when there are existing nodes to compare
  against. We fetch the N most recently extracted nodes from the same
  corpus layer as a proxy for semantic relevance. A future improvement
  would use embedding-based nearest-neighbour search.
  """

  require Logger

  alias Xwa.Documents
  alias Xwa.Graph.{Nodes, Edges}
  alias Xwa.Ingestion.{ClaimExtractor, EdgeExtractor}

  @neighbourhood_size 20

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Runs the full ingestion pipeline synchronously.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec run(String.t(), String.t()) :: :ok | {:error, term()}
  def run(document_id, requesting_user_id) do
    Logger.info("[Ingestion] Starting ingestion for document #{document_id}")

    result =
      with {:ok, doc, text} <- load_content(document_id, requesting_user_id),
           :ok <- advance_status(doc, "processing"),
           {:ok, nodes} <- extract_claims(doc, text, requesting_user_id),
           :ok <- insert_nodes_and_edges(nodes, doc, requesting_user_id),
           :ok <- insert_wiki_links(text, nodes, doc, requesting_user_id) do
        :ok
      end

    case result do
      :ok ->
        doc = Documents.get_document!(document_id)
        Documents.update_ingestion_status(doc, "complete")
        Logger.info("[Ingestion] Completed ingestion for document #{document_id}")
        :ok

      {:error, reason} ->
        Logger.error("[Ingestion] Failed ingestion for document #{document_id}: #{inspect(reason)}")

        case Documents.get_document(document_id) do
          nil -> :ok
          doc -> Documents.update_ingestion_status(doc, "failed", error: inspect(reason))
        end

        {:error, reason}
    end
  end

  @doc """
  Spawns the ingestion pipeline in a supervised Task.
  Returns the Task reference immediately.
  """
  @spec run_async(String.t(), String.t()) :: Task.t()
  def run_async(document_id, requesting_user_id) do
    Task.Supervisor.async_nolink(
      Xwa.TaskSupervisor,
      fn -> run(document_id, requesting_user_id) end
    )
  end

  # ---------------------------------------------------------------------------
  # Pipeline steps
  # ---------------------------------------------------------------------------

  defp load_content(document_id, requesting_user_id) do
    case Documents.get_decrypted_content(document_id, requesting_user_id) do
      {:ok, %{extracted_text: text}} when is_binary(text) and text != "" ->
        doc = Documents.get_document!(document_id)
        {:ok, doc, text}

      {:ok, %{extracted_text: nil}} ->
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

  defp extract_claims(doc, text, requesting_user_id) do
    context = %{
      document_id: doc.id,
      corpus_layer: doc.corpus_layer,
      source_type: doc.source_type,
      document_date: doc.document_date,
      created_by: requesting_user_id
    }

    case ClaimExtractor.extract(text, context) do
      {:ok, nodes} ->
        Logger.info("[Ingestion] Extracted #{length(nodes)} claims from document #{doc.id}")
        {:ok, nodes}

      {:error, reason} ->
        {:error, {:claim_extraction_failed, reason}}
    end
  end

  defp insert_nodes_and_edges(nodes, doc, requesting_user_id) do
    context = %{
      document_id: doc.id,
      created_by: requesting_user_id
    }

    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      case insert_node_with_edges(node, doc, context) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_node_with_edges(node, doc, context) do
    with {:ok, inserted_node} <- Nodes.create(node) do
      # Fetch semantically relevant neighbours from the same corpus layer.
      # Falls back to an empty list — edge extraction is skipped when empty.
      neighbours = fetch_neighbourhood(inserted_node, doc)

      case EdgeExtractor.extract(inserted_node, neighbours, context) do
        {:ok, edges} ->
          insert_edges(edges)

        {:error, reason} ->
          # Edge extraction failure is non-fatal — log and continue.
          Logger.warning(
            "[Ingestion] Edge extraction failed for node #{inserted_node.id}: #{inspect(reason)}"
          )

          :ok
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

  defp insert_wiki_links(text, claim_nodes, doc, requesting_user_id) do
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
        created_by: requesting_user_id
      }

      # Merge each concept node (create or find existing)
      concept_nodes =
        Enum.flat_map(phrases, fn phrase ->
          case Nodes.merge_concept(Map.put(context, :content, phrase)) do
            {:ok, node} -> [node]
            {:error, reason} ->
              Logger.warning("[Ingestion] Failed to merge concept node '#{phrase}': #{inspect(reason)}")
              []
          end
        end)

      # Create "mentions" edges from every claim node in this document to each concept
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
            certainty: "solid"
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

  defp fetch_neighbourhood(node, doc) do
    # Use corpus layer as a proxy for semantic relevance until embeddings exist.
    layer = doc.corpus_layer || node.corpus_layer

    candidates =
      if layer do
        case Nodes.list_by_corpus_layer(layer) do
          {:ok, nodes} -> nodes
          _ -> []
        end
      else
        case Nodes.list() do
          {:ok, nodes} -> nodes
          _ -> []
        end
      end

    # Exclude the node we just inserted, take most recent N.
    candidates
    |> Enum.reject(&(&1.id == node.id))
    |> Enum.take(@neighbourhood_size)
  end
end
