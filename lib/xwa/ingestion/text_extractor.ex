defmodule Xwa.Ingestion.TextExtractor do
  @moduledoc """
  Extracts plain text from uploaded documents by shelling out to pandoc.

  Pandoc handles: PDF (via pdftotext fallback), DOCX, ODT, HTML, Markdown,
  plain text, and many others. The extracted text is stored alongside the
  original binary in document_contents.extracted_text and used as the input
  for claim extraction.

  Pandoc must be installed and on the system PATH.
  """

  @doc """
  Extracts plain text from a binary given its MIME type.

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  def extract(binary, content_type) when is_binary(binary) and is_binary(content_type) do
    case content_type do
      t when t in ["text/plain", "text/markdown"] ->
        {:ok, String.trim(binary)}

      _ ->
        extract_via_pandoc(binary, content_type)
    end
  end

  defp extract_via_pandoc(binary, content_type) do
    input_format = pandoc_input_format(content_type)

    tmp_path = Path.join(System.tmp_dir!(), "xwa_extract_#{:erlang.unique_integer([:positive])}")

    try do
      File.write!(tmp_path, binary)

      args =
        if input_format do
          ["--from", input_format, "--to", "plain", "--wrap=none", tmp_path]
        else
          ["--to", "plain", "--wrap=none", tmp_path]
        end

      case System.cmd("pandoc", args, stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, String.trim(output)}

        {output, code} ->
          {:error, "pandoc exited with code #{code}: #{output}"}
      end
    rescue
      ErlangError -> {:error, :pandoc_not_found}
    after
      File.rm(tmp_path)
    end
  end

  @doc """
  Returns true if pandoc is available on PATH.
  """
  def available? do
    case System.cmd("pandoc", ["--version"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  # Map MIME types to pandoc input format identifiers.
  # nil means let pandoc auto-detect from the file extension/content.
  defp pandoc_input_format("application/pdf"), do: "pdf"
  defp pandoc_input_format("application/vnd.openxmlformats-officedocument.wordprocessingml.document"), do: "docx"
  defp pandoc_input_format("application/vnd.oasis.opendocument.text"), do: "odt"
  defp pandoc_input_format("text/html"), do: "html"
  defp pandoc_input_format("text/markdown"), do: "markdown"
  defp pandoc_input_format("text/plain"), do: "plain"
  defp pandoc_input_format(_), do: nil
end
