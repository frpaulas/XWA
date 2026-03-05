defmodule Xwa.Documents do
  @moduledoc """
  Context for managing source documents.

  Documents are the provenance layer for graph nodes (claims). A document
  record in Postgres always exists for every source, but the actual content
  may live anywhere depending on the storage backend:

    - :postgres — content stored inline in document_contents
    - :local    — content lives on the user's filesystem; storage_ref is the path
    - :s3       — content lives in an S3-compatible bucket; storage_ref is "bucket/key"
    - :url      — content is a remote URL; storage_ref is the full URL

  This means privacy-conscious users can keep their documents entirely local
  while still having their extracted claims in the graph.

  ## Encryption

  Document content (raw binary + extracted text) can be encrypted at rest in
  Postgres. The `encryption_tier` field on the document record indicates how:

    - nil    — stored plaintext
    - "app"  — encrypted with the app-level ENCRYPTION_KEY (default when
               encryption is requested but no per-user key exists)
    - "user" — encrypted with the owner's per-user key (stored wrapped in
               the user_keys table)

  Claims extracted from encrypted documents are stored plaintext in Memgraph
  — they are derived, abstracted content, not the author's original work.
  Access to claims is controlled separately via `public`/`shared_with` on the
  graph node.

  Use `register_document_with_content/3` to store and optionally encrypt
  content. Use `get_decrypted_content/2` to retrieve and decrypt it.
  """

  import Ecto.Query
  alias Xwa.Repo
  alias Xwa.Crypto
  alias Xwa.Documents.{Document, DocumentContent}
  alias Xwa.Accounts.UserKey

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Returns all documents, most recently inserted first.
  """
  def list_documents do
    Repo.all(from d in Document, order_by: [desc: d.inserted_at])
  end

  @doc """
  Returns documents belonging to a specific graph, most recently inserted first.
  """
  def list_documents_for_graph(graph_id) when is_binary(graph_id) do
    Repo.all(
      from d in Document,
        where: d.graph_id == ^graph_id,
        order_by: [desc: d.inserted_at]
    )
  end

  @doc """
  Gets a document by id, only if it belongs to the given graph.
  Returns nil if not found or not owned by the graph.
  """
  def get_document_for_graph(id, graph_id) do
    Repo.one(
      from d in Document,
        where: d.id == ^id and d.graph_id == ^graph_id
    )
  end

  @doc """
  Returns documents filtered by ingestion status.
  """
  def list_documents_by_status(status) when is_binary(status) do
    Repo.all(
      from d in Document, where: d.ingestion_status == ^status, order_by: [desc: d.inserted_at]
    )
  end

  @doc """
  Returns documents filtered by corpus layer.
  """
  def list_documents_by_corpus_layer(layer) when is_binary(layer) do
    Repo.all(
      from d in Document, where: d.corpus_layer == ^layer, order_by: [desc: d.document_date]
    )
  end

  @doc """
  Gets a single document by id. Raises if not found.
  """
  def get_document!(id), do: Repo.get!(Document, id)

  @doc """
  Gets a single document by id. Returns nil if not found.
  """
  def get_document(id), do: Repo.get(Document, id)

  @doc """
  Gets a document with its inline content preloaded (still encrypted if
  the document has an encryption_tier set). Use `get_decrypted_content/2`
  to retrieve content in plaintext.

  Only meaningful for :postgres backend documents.
  """
  def get_document_with_content!(id) do
    Repo.get!(Document, id) |> Repo.preload(:content)
  end

  @doc """
  Finds a document by content hash within a graph. Useful for deduplication during ingestion.
  Returns nil if not found.
  """
  def get_document_by_hash(hash, graph_id) when is_binary(hash) and is_binary(graph_id) do
    Repo.one(from d in Document, where: d.content_hash == ^hash and d.graph_id == ^graph_id)
  end

  @doc """
  Retrieves and decrypts content for a postgres-backend document.

  `requesting_user_id` — the UUID of the user requesting access. Required for
  "user"-tier documents to fetch and unwrap the owner's key.

  Returns `{:ok, %{content: binary | nil, extracted_text: string | nil}}`
  or `{:error, reason}`.

  Possible errors:
    - `:not_found` — document or content row does not exist
    - `:not_postgres_backend` — document content is not stored in Postgres
    - `:decryption_failed` — wrong key or corrupted data
    - `:no_user_key` — user-tier doc but owner has no key in user_keys
    - `:access_denied` — requesting user is not the owner (user-tier only)
  """
  def get_decrypted_content(document_id, requesting_user_id) do
    with %Document{} = doc <- Repo.get(Document, document_id) || {:error, :not_found},
         :ok <- check_postgres_backend(doc),
         %DocumentContent{} = content <-
           Repo.get_by(DocumentContent, document_id: document_id) || {:error, :not_found} do
      decrypt_content(content, doc, requesting_user_id)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Mutations
  # ---------------------------------------------------------------------------

  @doc """
  Registers a new document record.

  For :local, :s3, and :url backends, this records the metadata and where
  to find the content — the content itself is not touched.

  For :postgres backend, use `register_document_with_content/3` instead.
  """
  def register_document(attrs) do
    %Document{}
    |> Document.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Registers a new document and stores its content inline (Postgres backend only).

  `doc_attrs`     — attributes for the Document record (title, metadata, etc.)
  `content_attrs` — map with :content (binary) and/or :extracted_text (string)
  `opts`          — keyword options:
    - `:encrypt` — `:app` | `:user` | false (default: false)
    - `:owner_id` — required when `encrypt: :user`

  When `:encrypt` is set, both `content` and `extracted_text` are encrypted
  before insert. The `encryption_tier` field on the document record is set
  accordingly.

  Both inserts happen in a single transaction.
  """
  def register_document_with_content(doc_attrs, content_attrs, opts \\ []) do
    encrypt = Keyword.get(opts, :encrypt, false)
    owner_id = Keyword.get(opts, :owner_id)

    Repo.transaction(fn ->
      with {:ok, encrypted_content_attrs, tier} <-
             maybe_encrypt_content(content_attrs, encrypt, owner_id),
           doc_attrs_final =
             doc_attrs
             |> Map.put(:storage_backend, "postgres")
             |> Map.put(:encryption_tier, tier),
           {:ok, document} <-
             %Document{}
             |> Document.changeset(doc_attrs_final)
             |> Repo.insert(),
           {:ok, _content} <-
             %DocumentContent{}
             |> DocumentContent.changeset(
               Map.put(encrypted_content_attrs, :document_id, document.id)
             )
             |> Repo.insert() do
        document
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Updates a document's metadata.
  """
  def update_document(%Document{} = document, attrs) do
    document
    |> Document.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Advances a document's ingestion status.

  Used by the ingestion pipeline — only touches lifecycle fields,
  never metadata.
  """
  def update_ingestion_status(%Document{} = document, status, opts \\ []) do
    error = Keyword.get(opts, :error)

    ingested_at =
      if status == "complete", do: DateTime.utc_now() |> DateTime.truncate(:second), else: nil

    document
    |> Document.ingestion_changeset(%{
      ingestion_status: status,
      ingestion_error: error,
      ingested_at: ingested_at
    })
    |> Repo.update()
  end

  @doc """
  Deletes a document record. For :postgres backend documents, the content
  is cascade-deleted by the database. For other backends, only the metadata
  record is removed — the content itself is not touched.
  """
  def delete_document(%Document{} = document) do
    Repo.delete(document)
  end

  @doc """
  Returns true if any document in the graph is currently being processed.
  Used to enforce sequential ingestion.
  """
  def any_processing?(graph_id) do
    Repo.exists?(
      from d in Document,
        where: d.graph_id == ^graph_id and d.ingestion_status == "processing"
    )
  end

  @doc """
  Returns the oldest pending document for the graph, or nil.
  Used to pick up the next document after one finishes processing.
  """
  def next_pending(graph_id) do
    Repo.one(
      from d in Document,
        where: d.graph_id == ^graph_id and d.ingestion_status == "pending",
        order_by: [asc: d.inserted_at],
        limit: 1
    )
  end

  # ---------------------------------------------------------------------------
  # Changesets (for external use, e.g. forms)
  # ---------------------------------------------------------------------------

  @doc """
  Returns a changeset for a new document (useful for building forms).
  """
  def change_document(%Document{} = document \\ %Document{}, attrs \\ %{}) do
    Document.changeset(document, attrs)
  end

  # ---------------------------------------------------------------------------
  # Private — encryption helpers
  # ---------------------------------------------------------------------------

  defp check_postgres_backend(%Document{storage_backend: "postgres"}), do: :ok
  defp check_postgres_backend(_), do: {:error, :not_postgres_backend}

  # No encryption requested
  defp maybe_encrypt_content(content_attrs, false, _owner_id) do
    {:ok, content_attrs, nil}
  end

  # App-tier encryption
  defp maybe_encrypt_content(content_attrs, :app, _owner_id) do
    with {:ok, attrs} <- encrypt_content_fields(content_attrs, &Crypto.encrypt_app/1) do
      {:ok, attrs, "app"}
    end
  end

  # User-tier encryption — fetch owner's key from user_keys
  defp maybe_encrypt_content(content_attrs, :user, owner_id) when is_binary(owner_id) do
    with %UserKey{encrypted_key: wrapped_key} <-
           Repo.get_by(UserKey, user_id: owner_id, tier: "user") ||
             {:error, :no_user_key},
         {:ok, raw_key} <- Crypto.unwrap_user_key(wrapped_key),
         {:ok, attrs} <- encrypt_content_fields(content_attrs, &Crypto.encrypt(&1, raw_key)) do
      {:ok, attrs, "user"}
    end
  end

  defp maybe_encrypt_content(_content_attrs, :user, nil) do
    {:error, :owner_id_required_for_user_tier}
  end

  defp encrypt_content_fields(content_attrs, encrypt_fn) do
    with {:ok, encrypted_content} <- encrypt_field(content_attrs[:content], encrypt_fn),
         {:ok, encrypted_text} <- encrypt_field(content_attrs[:extracted_text], encrypt_fn) do
      {:ok,
       content_attrs
       |> maybe_put(:content, encrypted_content)
       |> maybe_put(:extracted_text, encrypted_text)}
    end
  end

  defp encrypt_field(nil, _fn), do: {:ok, nil}
  defp encrypt_field(value, encrypt_fn) when is_binary(value), do: encrypt_fn.(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp decrypt_content(%DocumentContent{} = content, %Document{encryption_tier: nil}, _user_id) do
    {:ok, %{content: content.content, extracted_text: content.extracted_text}}
  end

  defp decrypt_content(%DocumentContent{} = content, %Document{encryption_tier: "app"}, _user_id) do
    with {:ok, raw} <- decrypt_field(content.content, &Crypto.decrypt_app/1),
         {:ok, text} <- decrypt_field(content.extracted_text, &Crypto.decrypt_app/1) do
      {:ok, %{content: raw, extracted_text: text}}
    end
  end

  defp decrypt_content(
         %DocumentContent{} = content,
         %Document{encryption_tier: "user", created_by: owner_id},
         requesting_user_id
       ) do
    if requesting_user_id != owner_id do
      {:error, :access_denied}
    else
      with %UserKey{encrypted_key: wrapped_key} <-
             Repo.get_by(UserKey, user_id: owner_id, tier: "user") || {:error, :no_user_key},
           {:ok, raw_key} <- Crypto.unwrap_user_key(wrapped_key),
           {:ok, raw} <- decrypt_field(content.content, &Crypto.decrypt(&1, raw_key)),
           {:ok, text} <- decrypt_field(content.extracted_text, &Crypto.decrypt(&1, raw_key)) do
        {:ok, %{content: raw, extracted_text: text}}
      end
    end
  end

  defp decrypt_field(nil, _fn), do: {:ok, nil}
  defp decrypt_field(value, decrypt_fn) when is_binary(value), do: decrypt_fn.(value)
end
