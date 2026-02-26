defmodule Mix.Tasks.ImportSermons do
  @moduledoc """
  Bulk-imports sermon text files from a directory into XWA.

  Usage:
    mix import_sermons --dir testdata/sermons --user-id UUID --graph-id UUID [--skip 001]

  Options:
    --dir       Directory containing sermon .txt files (default: testdata/sermons)
    --user-id   UUID of the user to import as (created_by)
    --graph-id  UUID of the graph to import into
    --skip      Comma-separated list of discourse number prefixes to skip (e.g. "001,002")
  """

  use Mix.Task

  alias Xwa.Documents
  alias Xwa.Ingestion.IngestionWorker

  @shortdoc "Bulk import sermon text files into XWA"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [dir: :string, user_id: :string, graph_id: :string, skip: :string]
      )

    dir = opts[:dir] || "testdata/sermons"
    user_id = opts[:user_id] || raise "--user-id is required"
    graph_id = opts[:graph_id] || raise "--graph-id is required"
    skip_prefixes = (opts[:skip] || "") |> String.split(",", trim: true)

    files =
      dir
      |> Path.join("*.txt")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reject(fn path ->
        name = Path.basename(path)
        Enum.any?(skip_prefixes, fn prefix -> String.starts_with?(name, prefix) end)
      end)

    total = length(files)
    Mix.shell().info("Importing #{total} sermons from #{dir}...")

    results =
      Enum.with_index(files, 1)
      |> Enum.map(fn {path, idx} ->
        name = Path.basename(path, ".txt")
        Mix.shell().info("[#{idx}/#{total}] #{name}")
        import_file(path, user_id, graph_id)
      end)

    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    skip_count = Enum.count(results, &match?({:skip, _}, &1))
    err_count = Enum.count(results, &match?({:error, _}, &1))

    Mix.shell().info("")
    Mix.shell().info("Done: #{ok_count} imported, #{skip_count} skipped (duplicate), #{err_count} errors")
  end

  defp import_file(path, user_id, graph_id) do
    content = File.read!(path)
    filename = Path.basename(path)

    # Parse the header block to extract metadata
    {title, document_date} = parse_header(content, filename)

    binary = content
    content_type = "text/plain"
    content_hash = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

    case Documents.get_document_by_hash(content_hash, graph_id) do
      %Documents.Document{title: existing_title} ->
        Mix.shell().info("  -> skipped (already imported as \"#{existing_title}\")")
        {:skip, path}

      nil ->
        doc_attrs = %{
          title: title,
          filename: filename,
          content_type: content_type,
          byte_size: byte_size(binary),
          content_hash: content_hash,
          source_type: "aspirational",
          corpus_layer: "self_description",
          document_date: document_date,
          created_by: user_id,
          graph_id: graph_id
        }

        content_attrs = %{
          content: binary,
          extracted_text: content
        }

        case Documents.register_document_with_content(doc_attrs, content_attrs, encrypt: false, owner_id: user_id) do
          {:ok, document} ->
            IngestionWorker.run_async(document.id, user_id, graph_id)
            Mix.shell().info("  -> imported (id: #{document.id})")
            {:ok, document}

          {:error, changeset} ->
            Mix.shell().error("  -> ERROR: #{inspect(changeset.errors)}")
            {:error, changeset}
        end
    end
  end

  # Extract title from the header block:
  #   DISCOURSE 2 (II)
  #   Book: Genesis
  #   Scripture: Genesis ii. 2, 3
  #   Title: Appointment of the Sabbath
  defp parse_header(content, filename) do
    title =
      case Regex.run(~r/^Title:\s*(.+)$/m, content) do
        [_, t] -> String.trim(t)
        _ -> filename_to_title(filename)
      end

    # All volumes are from the 1845 7th edition
    document_date = ~D[1845-01-01]

    {title, document_date}
  end

  defp filename_to_title(filename) do
    filename
    |> Path.basename(".txt")
    |> String.replace(~r/^\d+_/, "")
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
