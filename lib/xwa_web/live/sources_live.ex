defmodule XwaWeb.SourcesLive do
  use XwaWeb, :live_view

  alias Xwa.Documents
  alias Xwa.Documents.Document
  alias Xwa.Ingestion.{TextExtractor, IngestionWorker}

  @max_upload_size_mb 50
  @accepted_types ~w(
    application/pdf
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.oasis.opendocument.text
    text/plain
    text/markdown
    text/html
  )

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      graph_id = socket.assigns.current_scope.graph_id
      if graph_id, do: Phoenix.PubSub.subscribe(Xwa.PubSub, "graph:#{graph_id}")
    end

    graph_id = socket.assigns.current_scope.graph_id
    documents = if graph_id, do: Documents.list_documents_for_graph(graph_id), else: []

    socket =
      socket
      |> assign(:documents, documents)
      |> assign(:show_upload_panel, false)
      |> assign(:panel_mode, :upload)
      |> assign(:upload_step, :file)
      |> assign(:pending_upload, nil)
      |> assign(:pending_binary, nil)
      |> assign(:pending_content_type, nil)
      |> assign(:pending_filename, nil)
      |> assign(:form, nil)
      |> allow_upload(:document,
        accept: @accepted_types,
        max_entries: 1,
        max_file_size: @max_upload_size_mb * 1_000_000,
        auto_upload: true
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("open_upload_panel", _params, socket) do
    {:noreply, assign(socket, show_upload_panel: true, panel_mode: :upload, upload_step: :file,
      pending_upload: nil, pending_binary: nil, pending_content_type: nil, pending_filename: nil, form: nil)}
  end

  def handle_event("close_upload_panel", _params, socket) do
    socket =
      socket
      |> assign(show_upload_panel: false, panel_mode: :upload, upload_step: :file,
          pending_upload: nil, pending_binary: nil, pending_content_type: nil, pending_filename: nil, form: nil)
      |> cancel_uploads()

    {:noreply, socket}
  end

  def handle_event("validate_upload", _params, socket) do
    case socket.assigns.uploads.document.entries do
      [entry | _] when socket.assigns.upload_step == :file ->
        send(self(), {:advance_to_metadata, entry.client_name})
      _ ->
        :ok
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:advance_to_metadata, filename}, socket) do
    socket = assign(socket,
      upload_step: :metadata,
      pending_filename: filename,
      form: to_form(Documents.change_document(%Document{}))
    )
    {:noreply, socket}
  end

  @impl true
  def handle_progress(:document, entry, socket) do
    socket =
      if entry.done? do
        results =
          consume_uploaded_entries(socket, :document, fn %{path: path}, e ->
            {File.read!(path), e.client_type, e.client_name}
          end)

        case results do
          [{binary, content_type, filename}] ->
            assign(socket,
              pending_binary: binary,
              pending_content_type: content_type,
              pending_filename: filename
            )
          _ ->
            socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("set_panel_mode", %{"mode" => mode}, socket) do
    mode_atom = if mode == "write", do: :write, else: :upload
    socket =
      socket
      |> assign(panel_mode: mode_atom, upload_step: :file,
          pending_binary: nil, pending_content_type: nil, pending_filename: nil, form: nil)
      |> cancel_uploads()
    {:noreply, socket}
  end

  def handle_event("proceed_from_editor", _params, socket) do
    binary = socket.assigns.pending_binary

    if is_nil(binary) or binary == "" do
      {:noreply, put_flash(socket, :error, "Please write some content first.")}
    else
      {:noreply, assign(socket,
        upload_step: :metadata,
        pending_content_type: "text/markdown",
        pending_filename: nil,
        form: to_form(Documents.change_document(%Document{}))
      )}
    end
  end


  def handle_event("validate_metadata", %{"document" => params}, socket) do
    form =
      %Document{}
      |> Documents.change_document(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("save_document", %{"document" => params}, socket) do
    user_id = socket.assigns.current_scope.user.id
    binary = socket.assigns.pending_binary
    content_type = socket.assigns.pending_content_type
    # In write mode pending_filename is nil; derive it from the title
    filename =
      socket.assigns.pending_filename ||
        (params["title"] |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")) <> ".md"

    if is_nil(binary) or binary == "" do
      socket =
        socket
        |> put_flash(:error, "Upload was lost. Please select the file again.")
        |> assign(upload_step: :file, pending_upload: nil, pending_binary: nil,
                  pending_content_type: nil, pending_filename: nil, form: nil)

      {:noreply, socket}
    else
        content_hash = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

        case Documents.get_document_by_hash(content_hash) do
          %Document{} = existing ->
            socket =
              socket
              |> put_flash(:error, "This document has already been imported: \"#{existing.title}\"")
              |> assign(show_upload_panel: false, upload_step: :file, pending_upload: nil,
                        pending_binary: nil, pending_content_type: nil, pending_filename: nil, form: nil)

            {:noreply, socket}

          nil ->
            extracted_text =
              case TextExtractor.extract(binary, content_type) do
                {:ok, text} -> text
                {:error, _} -> nil
              end

            doc_attrs = %{
              title: params["title"],
              filename: filename,
              content_type: content_type,
              byte_size: byte_size(binary),
              content_hash: content_hash,
              source_type: params["source_type"],
              corpus_layer: params["corpus_layer"],
              document_date: parse_date(params["document_date"]),
              created_by: user_id
            }

            content_attrs = %{
              content: binary,
              extracted_text: extracted_text
            }

            encrypt_opt = if params["encrypt"] == "true", do: :app, else: false

            case Documents.register_document_with_content(doc_attrs, content_attrs,
                   encrypt: encrypt_opt,
                   owner_id: user_id
                 ) do
              {:ok, document} ->
                graph_id = socket.assigns.current_scope.graph_id
                IngestionWorker.run_async(document.id, user_id, graph_id)

                documents = Documents.list_documents()

                socket =
                  socket
                  |> put_flash(:info, "Document imported. Extracting claims in the background…")
                  |> assign(
                    documents: documents,
                    show_upload_panel: false,
                    upload_step: :file,
                    pending_upload: nil,
                    pending_binary: nil,
                    pending_content_type: nil,
                    pending_filename: nil,
                    form: nil
                  )

                {:noreply, socket}

              {:error, changeset} ->
                {:noreply, assign(socket, form: to_form(changeset))}
            end
        end
    end
  end

  def handle_event("editor_change", %{"value" => value}, socket) do
    {:noreply, assign(socket, pending_binary: value)}
  end

  def handle_event("cancel_entry", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :document, ref)}
  end

  def handle_event("retry_ingestion", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    graph_id = socket.assigns.current_scope.graph_id

    case Documents.get_document_for_graph(id, graph_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Document not found.")}

      doc ->
        Documents.update_ingestion_status(doc, "pending")
        IngestionWorker.run_async(doc.id, user_id, graph_id)
        {:noreply, assign(socket, :documents, Documents.list_documents_for_graph(graph_id))}
    end
  end

  @impl true
  def handle_info({event, _document_id}, socket)
      when event in [:ingestion_complete, :ingestion_failed] do
    graph_id = socket.assigns.current_scope.graph_id
    documents = if graph_id, do: Documents.list_documents_for_graph(graph_id), else: []
    {:noreply, assign(socket, :documents, documents)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp cancel_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.document.entries, socket, fn entry, acc ->
      cancel_upload(acc, :document, entry.ref)
    end)
  end

  defp parse_date(""), do: nil
  defp parse_date(nil), do: nil

  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp format_bytes(bytes) when bytes < 1_000, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_000_000, do: "#{Float.round(bytes / 1_000, 1)} KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  defp status_badge_class("pending"), do: "bg-warning/15 text-warning-content border-warning/30"
  defp status_badge_class("processing"), do: "bg-info/15 text-info-content border-info/30"
  defp status_badge_class("complete"), do: "bg-success/15 text-success-content border-success/30"
  defp status_badge_class("failed"), do: "bg-error/15 text-error-content border-error/30"
  defp status_badge_class(_), do: "bg-base-200 text-base-content/60 border-base-300"

  defp corpus_layer_label("self_description"), do: "Self-description"
  defp corpus_layer_label("internal_record"), do: "Internal record"
  defp corpus_layer_label("external_context"), do: "External context"
  defp corpus_layer_label(other), do: other

  defp source_type_label("aspirational"), do: "Aspirational"
  defp source_type_label("operational"), do: "Operational"
  defp source_type_label("external"), do: "External"
  defp source_type_label(other), do: other

  defp file_icon("application/pdf"), do: "hero-document-text"
  defp file_icon("application/vnd.openxmlformats-officedocument.wordprocessingml.document"), do: "hero-document-text"
  defp file_icon("application/vnd.oasis.opendocument.text"), do: "hero-document-text"
  defp file_icon(_), do: "hero-document"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <%!-- Page header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold tracking-tight text-base-content">Sources</h1>
            <p class="mt-1 text-sm text-base-content/55">
              Documents feeding the knowledge graph
            </p>
          </div>
          <button
            id="add-document-btn"
            phx-click="open_upload_panel"
            class="inline-flex items-center gap-2 rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-content shadow-sm hover:brightness-110 active:scale-95 transition-all"
          >
            <.icon name="hero-plus" class="w-4 h-4" /> Add document
          </button>
        </div>

        <%!-- Document list --%>
        <%= if @documents == [] do %>
          <div class="flex flex-col items-center justify-center rounded-2xl border border-dashed border-base-300 bg-base-100 py-20 text-center">
            <div class="flex h-12 w-12 items-center justify-center rounded-xl bg-base-200 mb-4">
              <.icon name="hero-circle-stack" class="w-6 h-6 text-base-content/40" />
            </div>
            <p class="text-sm font-medium text-base-content/60">No documents yet</p>
            <p class="text-xs text-base-content/40 mt-1">Import a document to get started</p>
          </div>
        <% else %>
          <div class="rounded-2xl border border-base-200 bg-base-100 overflow-hidden">
            <table class="w-full text-sm">
              <thead>
                <tr class="border-b border-base-200 bg-base-200/50">
                  <th class="px-4 py-3 text-left font-medium text-base-content/60 w-full">Document</th>
                  <th class="px-4 py-3 text-left font-medium text-base-content/60 whitespace-nowrap hidden md:table-cell">Layer</th>
                  <th class="px-4 py-3 text-left font-medium text-base-content/60 whitespace-nowrap hidden sm:table-cell">Type</th>
                  <th class="px-4 py-3 text-left font-medium text-base-content/60 whitespace-nowrap">Status</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-200">
                <%= for doc <- @documents do %>
                  <tr class="hover:bg-base-200/30 transition-colors">
                    <td class="px-4 py-3">
                      <div class="flex items-center gap-3">
                        <div class="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary/10">
                          <.icon name={file_icon(doc.content_type)} class="w-4 h-4 text-primary" />
                        </div>
                        <div class="min-w-0">
                          <p class="font-medium text-base-content truncate">{doc.title}</p>
                          <p class="text-xs text-base-content/45 mt-0.5">
                            {doc.filename} · {format_bytes(doc.byte_size || 0)}
                            <%= if doc.document_date do %>
                              · {Calendar.strftime(doc.document_date, "%b %-d, %Y")}
                            <% end %>
                          </p>
                        </div>
                      </div>
                    </td>
                    <td class="px-4 py-3 hidden md:table-cell">
                      <span class="text-xs text-base-content/60">{corpus_layer_label(doc.corpus_layer)}</span>
                    </td>
                    <td class="px-4 py-3 hidden sm:table-cell">
                      <span class="text-xs text-base-content/60">{source_type_label(doc.source_type)}</span>
                    </td>
                    <td class="px-4 py-3">
                      <div class="flex items-center gap-2 flex-wrap">
                        <span class={[
                          "inline-flex items-center rounded-full border px-2 py-0.5 text-xs font-medium capitalize",
                          status_badge_class(doc.ingestion_status)
                        ]}>
                          {doc.ingestion_status}
                        </span>
                        <%= if doc.ingestion_status == "failed" do %>
                          <%= if doc.ingestion_error do %>
                            <button
                              id={"copy-error-#{doc.id}"}
                              phx-hook="CopyToClipboard"
                              data-clipboard={doc.ingestion_error}
                              title="Copy error to clipboard"
                              class="text-error/50 hover:text-error transition-all"
                            >
                              <.icon name="hero-clipboard-document" class="w-4 h-4" />
                            </button>
                          <% end %>
                          <button
                            phx-click="retry_ingestion"
                            phx-value-id={doc.id}
                            class="inline-flex items-center gap-1 rounded-md bg-warning/15 border border-warning/30 px-2 py-0.5 text-xs font-medium text-warning-content hover:bg-warning/25 transition-colors"
                          >
                            <.icon name="hero-arrow-path" class="w-3 h-3" /> Retry
                          </button>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>

      <%!-- Upload panel backdrop + slide-in / write modal --%>
      <%= if @show_upload_panel do %>
        <div
          id="upload-backdrop"
          class="fixed inset-0 z-40 bg-base-content/20 backdrop-blur-sm"
          phx-click="close_upload_panel"
        >
        </div>

        <div
          id="upload-panel"
          class={[
            "fixed z-50 bg-base-100 shadow-2xl flex flex-col",
            if(@panel_mode == :write and @upload_step == :file,
              do: "inset-4 rounded-2xl md:inset-8 lg:inset-16",
              else: "right-0 top-0 h-full w-full max-w-lg")
          ]}
        >
          <%!-- Panel header --%>
          <div class="flex items-center justify-between border-b border-base-200 px-6 py-4 shrink-0">
            <div>
              <h2 class="text-base font-semibold text-base-content">Add document</h2>
              <p class="text-xs text-base-content/50 mt-0.5">
                <%= if @upload_step == :file, do: "Step 1 of 2 — #{if @panel_mode == :write, do: "Write content", else: "Select file"}", else: "Step 2 of 2 — Document details" %>
              </p>
            </div>
            <button
              phx-click="close_upload_panel"
              class="flex h-8 w-8 items-center justify-center rounded-lg text-base-content/50 hover:text-base-content hover:bg-base-200 transition-colors"
            >
              <.icon name="hero-x-mark" class="w-5 h-5" />
            </button>
          </div>

          <%!-- Mode tabs (only shown on step 1) --%>
          <%= if @upload_step == :file do %>
            <div class="flex border-b border-base-200 px-6 shrink-0">
              <button
                phx-click="set_panel_mode"
                phx-value-mode="upload"
                class={[
                  "flex items-center gap-1.5 px-3 py-3 text-sm font-medium border-b-2 transition-colors",
                  if(@panel_mode == :upload,
                    do: "border-primary text-primary",
                    else: "border-transparent text-base-content/50 hover:text-base-content")
                ]}
              >
                <.icon name="hero-arrow-up-tray" class="w-4 h-4" /> Upload
              </button>
              <button
                phx-click="set_panel_mode"
                phx-value-mode="write"
                class={[
                  "flex items-center gap-1.5 px-3 py-3 text-sm font-medium border-b-2 transition-colors",
                  if(@panel_mode == :write,
                    do: "border-primary text-primary",
                    else: "border-transparent text-base-content/50 hover:text-base-content")
                ]}
              >
                <.icon name="hero-pencil-square" class="w-4 h-4" /> Write
              </button>
            </div>
          <% end %>

          <%!-- Step indicator --%>
          <div class="flex px-6 pt-4 pb-2 gap-2 shrink-0">
            <div class="h-1 flex-1 rounded-full bg-primary"></div>
            <div class={[
              "h-1 flex-1 rounded-full transition-colors",
              if(@upload_step == :metadata, do: "bg-primary", else: "bg-base-300")
            ]}>
            </div>
          </div>

          <%!-- Panel body --%>
          <div class="flex-1 px-6 py-4 overflow-y-auto">
            <%= cond do %>
              <% @upload_step == :metadata -> %>
                <.metadata_step form={@form} pending_upload={@pending_upload} panel_mode={@panel_mode} pending_filename={@pending_filename} />
              <% @panel_mode == :write -> %>
                <.write_step />
              <% true -> %>
                <.file_step uploads={@uploads} />
            <% end %>
          </div>

          <%!-- Panel footer --%>
          <div class="border-t border-base-200 px-6 py-4 shrink-0 flex justify-end gap-3">
            <button
              phx-click="close_upload_panel"
              class="rounded-lg border border-base-300 px-4 py-2 text-sm font-medium text-base-content/70 hover:bg-base-200 transition-colors"
            >
              Cancel
            </button>
            <%= cond do %>
              <% @upload_step == :metadata -> %>
                <%
                  uploading? = is_nil(@pending_binary) and @panel_mode == :upload
                %>
                <button
                  form="document-form"
                  type="submit"
                  disabled={uploading?}
                  class="inline-flex items-center gap-2 rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-content hover:brightness-110 active:scale-95 transition-all disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  <%= if uploading? do %>
                    <span class="loading loading-spinner loading-xs"></span> Uploading…
                  <% else %>
                    <.icon name="hero-arrow-up-tray" class="w-4 h-4" /> Import
                  <% end %>
                </button>
              <% @panel_mode == :write -> %>
                <button
                  phx-click="proceed_from_editor"
                  class="inline-flex items-center gap-2 rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-primary-content hover:brightness-110 active:scale-95 transition-all"
                >
                  Continue <.icon name="hero-arrow-right" class="w-4 h-4" />
                </button>
              <% true -> %>
                <%!-- No action until a file is selected --%>
            <% end %>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Sub-components
  # ---------------------------------------------------------------------------

  defp file_step(assigns) do
    ~H"""
    <form phx-change="validate_upload">
      <label
        id="file-drop-zone"
        phx-drop-target={@uploads.document.ref}
        class="flex flex-col items-center justify-center rounded-2xl border-2 border-dashed border-base-300 bg-base-200/30 px-8 py-14 text-center hover:border-primary/50 hover:bg-primary/5 transition-colors cursor-pointer"
      >
        <.live_file_input upload={@uploads.document} class="sr-only" />

        <div class="flex h-14 w-14 items-center justify-center rounded-2xl bg-base-200 mb-4">
          <.icon name="hero-arrow-up-tray" class="w-7 h-7 text-base-content/40" />
        </div>
        <p class="text-sm font-medium text-base-content">
          Drop a file here or <span class="text-primary hover:underline">browse</span>
        </p>
        <p class="text-xs text-base-content/45 mt-2">
          PDF, DOCX, ODT, TXT, Markdown, HTML — up to 50 MB
        </p>
      </label>
    </form>

    <%!-- Entry preview --%>
    <%= for entry <- @uploads.document.entries do %>
      <div class="mt-4 flex items-center gap-3 rounded-xl border border-base-200 bg-base-100 p-3">
        <div class="flex h-9 w-9 shrink-0 items-center justify-center rounded-lg bg-primary/10">
          <.icon name="hero-document-text" class="w-5 h-5 text-primary" />
        </div>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-medium text-base-content truncate">{entry.client_name}</p>
          <p class="text-xs text-base-content/50 mt-0.5">{format_bytes(entry.client_size)}</p>
          <%= if entry.valid? do %>
            <div class="mt-1.5 h-1 w-full rounded-full bg-base-300 overflow-hidden">
              <div
                class="h-full rounded-full bg-primary transition-all"
                style={"width: #{entry.progress}%"}
              >
              </div>
            </div>
          <% end %>
          <%= for err <- upload_errors(@uploads.document, entry) do %>
            <p class="text-xs text-error mt-1">{upload_error_message(err)}</p>
          <% end %>
        </div>
        <button
          phx-click="cancel_entry"
          phx-value-ref={entry.ref}
          class="flex h-7 w-7 shrink-0 items-center justify-center rounded-lg text-base-content/40 hover:text-error hover:bg-error/10 transition-colors"
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>
    <% end %>

    <%= for err <- upload_errors(@uploads.document) do %>
      <p class="mt-2 text-xs text-error">{upload_error_message(err)}</p>
    <% end %>
    """
  end

  defp metadata_step(assigns) do
    ~H"""
    <div class="mb-5 flex items-center gap-3 rounded-xl border border-base-200 bg-base-200/40 p-3">
      <div class="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary/10">
        <.icon name={if @panel_mode == :write, do: "hero-pencil-square", else: "hero-document-text"} class="w-4 h-4 text-primary" />
      </div>
      <div class="min-w-0">
        <%= if @panel_mode == :write do %>
          <p class="text-sm font-medium text-base-content">Markdown document</p>
          <p class="text-xs text-base-content/50">Written in editor</p>
        <% else %>
          <p class="text-sm font-medium text-base-content truncate">{@pending_upload.client_name}</p>
          <p class="text-xs text-base-content/50">{format_bytes(@pending_upload.client_size)}</p>
        <% end %>
      </div>
    </div>

    <.form
      for={@form}
      id="document-form"
      phx-change="validate_metadata"
      phx-submit="save_document"
      class="space-y-4"
    >
      <div>
        <label class="block text-sm font-medium text-base-content mb-1.5">
          Title <span class="text-error">*</span>
        </label>
        <.input
          field={@form[:title]}
          type="text"
          placeholder="e.g. Advent 4C Sermon — December 2024"
          class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content placeholder:text-base-content/35 focus:border-primary focus:outline-none focus:ring-1 focus:ring-primary transition-colors"
        />
      </div>

      <div>
        <label class="block text-sm font-medium text-base-content mb-1.5">
          Corpus layer <span class="text-error">*</span>
        </label>
        <.input
          field={@form[:corpus_layer]}
          type="select"
          prompt="Select a layer…"
          options={[
            {"Self-description — aspirational, official comms", "self_description"},
            {"Internal record — minutes, decisions, post-mortems", "internal_record"},
            {"External context — analysis, reports, regulatory docs", "external_context"}
          ]}
          class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content focus:border-primary focus:outline-none focus:ring-1 focus:ring-primary transition-colors"
        />
      </div>

      <div>
        <label class="block text-sm font-medium text-base-content mb-1.5">
          Source type
        </label>
        <.input
          field={@form[:source_type]}
          type="select"
          prompt="Select a type…"
          options={[
            {"Aspirational — what the institution wants to believe", "aspirational"},
            {"Operational — what actually happened", "operational"},
            {"External — outside perspective or data", "external"}
          ]}
          class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content focus:border-primary focus:outline-none focus:ring-1 focus:ring-primary transition-colors"
        />
      </div>

      <div>
        <label class="block text-sm font-medium text-base-content mb-1.5">
          Document date
        </label>
        <.input
          field={@form[:document_date]}
          type="date"
          class="w-full rounded-lg border border-base-300 bg-base-100 px-3 py-2 text-sm text-base-content focus:border-primary focus:outline-none focus:ring-1 focus:ring-primary transition-colors"
        />
        <p class="mt-1 text-xs text-base-content/45">
          When the institution produced this document, not when you imported it.
        </p>
      </div>

      <div class="rounded-xl border border-base-200 bg-base-200/30 p-3">
        <label class="flex items-start gap-3 cursor-pointer">
          <input
            type="checkbox"
            name="document[encrypt]"
            value="true"
            class="mt-0.5 h-4 w-4 rounded border-base-300 text-primary focus:ring-primary"
          />
          <div>
            <p class="text-sm font-medium text-base-content">Encrypt source content</p>
            <p class="text-xs text-base-content/50 mt-0.5">
              Raw file and extracted text are encrypted at rest with the app key.
              Extracted claims are always stored plaintext.
            </p>
          </div>
        </label>
      </div>
    </.form>
    """
  end

  defp write_step(assigns) do
    ~H"""
    <div
      id="monaco-fix-wrapper"
      phx-hook="MonacoFix"
      style="height: calc(100vh - 259px); overflow: hidden;"
    >
      <LiveMonacoEditor.code_editor
        value=""
        change="editor_change"
        opts={%{
          "language" => "markdown",
          "minimap" => %{"enabled" => false},
          "wordWrap" => "on",
          "lineNumbers" => "off",
          "scrollBeyondLastLine" => false,
          "fontSize" => 14,
          "padding" => %{"top" => 12}
        }}
        style="height: 100%; width: 100%;"
      />
    </div>
    """
  end

  defp upload_error_message(:too_large), do: "File is too large (max 50 MB)"
  defp upload_error_message(:not_accepted), do: "File type not supported"
  defp upload_error_message(:too_many_files), do: "Only one file at a time"
  defp upload_error_message(err), do: "Upload error: #{inspect(err)}"
end
