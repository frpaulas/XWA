defmodule XwaWeb.AdminUploadLive do
  use XwaWeb, :live_view

  alias Xwa.Documents
  alias Xwa.Documents.Document
  alias Xwa.Graphs
  alias Xwa.Ingestion.{TextExtractor, IngestionWorker, ExtractionRuns}
  alias XwaWeb.Layouts

  @max_upload_size_mb 50
  @accepted_types ~w(
    application/pdf
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.oasis.opendocument.text
    text/plain
    text/markdown
    text/html
    .pdf
    .docx
    .odt
    .txt
    .md
    .html
    .htm
  )

  @impl true
  def mount(_params, _session, socket) do
    graphs = Graphs.list_all_graphs()
    default_graph_id = graphs |> List.first() |> then(&(&1 && &1.id))

    documents =
      if default_graph_id,
        do: Documents.list_documents_for_graph(default_graph_id),
        else: []

    if connected?(socket) && default_graph_id do
      Phoenix.PubSub.subscribe(Xwa.PubSub, "graph:#{default_graph_id}")
    end

    socket =
      socket
      |> assign(:graphs, graphs)
      |> assign(:selected_graph_id, default_graph_id)
      |> assign(:documents, documents)
      |> assign(:monthly_costs, ExtractionRuns.monthly_cost_summary())
      |> assign(:pending_files, [])
      |> assign(:upload_step, :files)
      |> assign(:form, nil)
      |> allow_upload(:documents,
        accept: @accepted_types,
        max_entries: 10,
        max_file_size: @max_upload_size_mb * 1_000_000,
        auto_upload: true,
        progress: &handle_progress/3
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("select_graph", %{"graph_id" => graph_id}, socket) do
    # Unsubscribe from old graph, subscribe to new one
    if old = socket.assigns.selected_graph_id do
      Phoenix.PubSub.unsubscribe(Xwa.PubSub, "graph:#{old}")
    end

    Phoenix.PubSub.subscribe(Xwa.PubSub, "graph:#{graph_id}")
    documents = Documents.list_documents_for_graph(graph_id)

    {:noreply, assign(socket, selected_graph_id: graph_id, documents: documents)}
  end

  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_entry", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :documents, ref)}
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
    graph_id = socket.assigns.selected_graph_id

    case socket.assigns.pending_files do
      [] ->
        {:noreply, put_flash(socket, :error, "No files to import.")}

      files ->
        results =
          Enum.map(files, fn %{binary: binary, content_type: content_type, filename: filename} ->
            content_hash = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

            case Documents.get_document_by_hash(content_hash, graph_id) do
              %Document{} = existing ->
                {:duplicate, existing.title}

              nil ->
                extracted_text =
                  case TextExtractor.extract(binary, content_type) do
                    {:ok, text} -> text
                    {:error, _} -> nil
                  end

                doc_attrs = %{
                  title: derive_title(params["title"], filename, files),
                  filename: filename,
                  content_type: content_type,
                  byte_size: byte_size(binary),
                  content_hash: content_hash,
                  source_type: params["source_type"],
                  corpus_layer: params["corpus_layer"],
                  document_date: parse_date(params["document_date"]),
                  created_by: user_id,
                  graph_id: graph_id
                }

                content_attrs = %{content: binary, extracted_text: extracted_text}

                case Documents.register_document_with_content(doc_attrs, content_attrs,
                       encrypt: :app,
                       owner_id: user_id
                     ) do
                  {:ok, document} ->
                    IngestionWorker.run_async(document.id, user_id, graph_id)
                    {:ok, document.title}

                  {:error, changeset} ->
                    {:error, changeset}
                end
            end
          end)

        errors = Enum.filter(results, &match?({:error, _}, &1))

        if errors == [] do
          imported = Enum.count(results, &match?({:ok, _}, &1))
          duplicates = Enum.count(results, &match?({:duplicate, _}, &1))

          msg =
            cond do
              duplicates == 0 -> "#{imported} document(s) queued for ingestion."
              imported == 0 -> "All #{duplicates} document(s) already imported (skipped)."
              true -> "#{imported} queued, #{duplicates} duplicate(s) skipped."
            end

          socket =
            socket
            |> put_flash(:info, msg)
            |> assign(
              pending_files: [],
              upload_step: :files,
              form: nil,
              documents: Documents.list_documents_for_graph(graph_id),
              monthly_costs: ExtractionRuns.monthly_cost_summary()
            )

          {:noreply, socket}
        else
          # Return first changeset error to form
          {:error, changeset} = List.first(errors)
          {:noreply, assign(socket, form: to_form(changeset))}
        end
    end
  end

  def handle_event("back_to_files", _params, socket) do
    {:noreply, assign(socket, upload_step: :files, pending_files: [], form: nil)}
  end

  def handle_event("retry_ingestion", %{"id" => id}, socket) do
    user_id = socket.assigns.current_scope.user.id
    graph_id = socket.assigns.selected_graph_id

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
    documents = Documents.list_documents_for_graph(socket.assigns.selected_graph_id)
    {:noreply, assign(socket, documents: documents, monthly_costs: ExtractionRuns.monthly_cost_summary())}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp handle_progress(:documents, entry, socket) do
    socket =
      if entry.done? and entry.valid? do
        [{binary, content_type, filename}] =
          consume_uploaded_entries(socket, :documents, fn %{path: path}, e ->
            {File.read!(path), e.client_type, e.client_name}
          end)

        file = %{binary: binary, content_type: content_type, filename: filename}
        pending = socket.assigns.pending_files ++ [file]

        assign(socket, pending_files: pending, upload_step: :metadata,
          form: to_form(Documents.change_document(%Document{})))
      else
        socket
      end

    {:noreply, socket}
  end

  # When batch-uploading multiple files, use the filename as title; for single
  # files, use the user-supplied title field if provided.
  defp derive_title(title_param, filename, files) do
    if length(files) > 1 or is_nil(title_param) or String.trim(title_param) == "" do
      filename |> Path.rootname() |> String.replace(~r/[-_]+/, " ") |> String.trim()
    else
      String.trim(title_param)
    end
  end

  defp current_month, do: Date.utc_today() |> Calendar.strftime("%Y-%m")

  defp format_number(nil), do: "0"
  defp format_number(n) when is_integer(n) do
    n |> Integer.to_string() |> String.reverse() |> String.graphemes()
    |> Enum.chunk_every(3) |> Enum.join(",") |> String.reverse()
  end
  defp format_number(n), do: format_number(trunc(n))

  defp format_cost(nil), do: "0.00"
  defp format_cost(%Decimal{} = d), do: Decimal.round(d, 2) |> Decimal.to_string()
  defp format_cost(n), do: format_cost(Decimal.new("#{n}"))

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
    <div class="max-w-4xl mx-auto p-6">
      <h1 class="text-2xl font-bold mb-6">Admin: Document Upload</h1>

      <%!-- Graph selector --%>
      <div class="mb-6">
        <label class="block text-sm font-medium mb-1">Target Graph</label>
        <select
          class="select select-bordered w-full max-w-sm"
          phx-change="select_graph"
          name="graph_id"
        >
          <option :for={g <- @graphs} value={g.id} selected={g.id == @selected_graph_id}>
            <%= g.name %> — <%= g.owner_email %>
          </option>
        </select>
      </div>

      <%!-- Upload / Metadata steps --%>
      <div class="card bg-base-200 p-6 mb-8">
        <%= if @upload_step == :files do %>
          <h2 class="text-lg font-semibold mb-4">Upload Documents (up to 10)</h2>
          <form phx-change="validate_upload" phx-drop-target={@uploads.documents.ref}>
            <.live_file_input upload={@uploads.documents} class="file-input file-input-bordered w-full mb-4" />
          </form>
          <div :if={@uploads.documents.entries != []} class="mt-2 space-y-1">
            <div :for={entry <- @uploads.documents.entries} class="flex items-center gap-2 text-sm">
              <span class="flex-1"><%= entry.client_name %></span>
              <progress class="progress w-32" value={entry.progress} max="100" />
              <button phx-click="cancel_entry" phx-value-ref={entry.ref} class="btn btn-xs btn-ghost">✕</button>
            </div>
          </div>
        <% else %>
          <h2 class="text-lg font-semibold mb-1">Document Metadata</h2>
          <p class="text-sm text-base-content/60 mb-4">
            <%= length(@pending_files) %> file(s) ready.
            <%= if length(@pending_files) > 1 do %>
              Titles will be derived from filenames.
            <% end %>
          </p>

          <.form for={@form} phx-change="validate_metadata" phx-submit="save_document">
            <%= if length(@pending_files) == 1 do %>
              <div class="form-control mb-3">
                <label class="label"><span class="label-text">Title</span></label>
                <.input field={@form[:title]} type="text" placeholder="Document title" />
              </div>
            <% end %>

            <div class="grid grid-cols-2 gap-4 mb-3">
              <div class="form-control">
                <label class="label"><span class="label-text">Source Type</span></label>
                <.input field={@form[:source_type]} type="select"
                  options={[{"Aspirational", "aspirational"}, {"Operational", "operational"}, {"External", "external"}]} />
              </div>
              <div class="form-control">
                <label class="label"><span class="label-text">Corpus Layer</span></label>
                <.input field={@form[:corpus_layer]} type="select"
                  options={[{"Self Description", "self_description"}, {"Internal Record", "internal_record"}, {"External Context", "external_context"}]} />
              </div>
            </div>

            <div class="form-control mb-4">
              <label class="label"><span class="label-text">Document Date (optional)</span></label>
              <.input field={@form[:document_date]} type="date" />
            </div>

            <div class="flex gap-3">
              <button type="submit" class="btn btn-primary">Import</button>
              <button type="button" phx-click="back_to_files" class="btn btn-ghost">Back</button>
            </div>
          </.form>
        <% end %>
      </div>

      <%!-- Document list for selected graph --%>
      <%!-- Monthly cost summary --%>
      <h2 class="text-lg font-semibold mb-3">Ingestion Costs</h2>
      <div :if={@monthly_costs == []} class="text-sm text-base-content/50 mb-8">
        No extraction runs yet.
      </div>
      <div :if={@monthly_costs != []} class="mb-8 overflow-x-auto">
        <table class="table table-sm w-full">
          <thead>
            <tr>
              <th>Month</th>
              <th class="text-right">Runs</th>
              <th class="text-right">Input tokens</th>
              <th class="text-right">Output tokens</th>
              <th class="text-right">Cost (USD)</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @monthly_costs}>
              <td class={if row.month == current_month(), do: "font-semibold", else: ""}>
                <%= row.month %><%= if row.month == current_month(), do: " (MTD)" %>
              </td>
              <td class="text-right"><%= row.runs %></td>
              <td class="text-right"><%= format_number(row.input_tokens) %></td>
              <td class="text-right"><%= format_number(row.output_tokens) %></td>
              <td class="text-right font-mono">$<%= format_cost(row.cost_usd) %></td>
            </tr>
          </tbody>
          <tfoot>
            <tr class="font-semibold">
              <td>Total</td>
              <td class="text-right"><%= Enum.sum(Enum.map(@monthly_costs, & &1.runs)) %></td>
              <td class="text-right"><%= format_number(Enum.sum(Enum.map(@monthly_costs, &(&1.input_tokens || 0)))) %></td>
              <td class="text-right"><%= format_number(Enum.sum(Enum.map(@monthly_costs, &(&1.output_tokens || 0)))) %></td>
              <td class="text-right font-mono">
                $<%= @monthly_costs
                    |> Enum.map(&(Decimal.new(&1.cost_usd || 0)))
                    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
                    |> format_cost() %>
              </td>
            </tr>
          </tfoot>
        </table>
      </div>

      <h2 class="text-lg font-semibold mb-3">Documents in this Graph</h2>
      <div :if={@documents == []} class="text-sm text-base-content/50">No documents yet.</div>
      <table :if={@documents != []} class="table table-sm w-full">
        <thead>
          <tr>
            <th>Title</th>
            <th>Status</th>
            <th>Date</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={doc <- @documents}>
            <td class="max-w-xs truncate"><%= doc.title %></td>
            <td>
              <span class={[
                "badge badge-sm",
                doc.ingestion_status == "complete" && "badge-success",
                doc.ingestion_status == "processing" && "badge-warning",
                doc.ingestion_status == "failed" && "badge-error",
                doc.ingestion_status == "pending" && "badge-ghost"
              ]}>
                <%= doc.ingestion_status %>
              </span>
            </td>
            <td><%= doc.document_date %></td>
            <td>
              <button
                :if={doc.ingestion_status in ["failed", "pending"]}
                phx-click="retry_ingestion"
                phx-value-id={doc.id}
                class="btn btn-xs btn-ghost"
              >
                Retry
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    </Layouts.app>
    """
  end
end
