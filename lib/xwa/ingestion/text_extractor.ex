defmodule Xwa.Ingestion.TextExtractor do
  @moduledoc """
  Extracts plain text from uploaded documents.

  Strategy by type:
  - PDF: pdftotext (poppler-utils) first; pandoc as fallback
  - DOCX/ODT/HTML/Markdown: pandoc
  - plain text: returned as-is

  The extracted text is stored in document_contents.extracted_text and used
  as the input for claim extraction.
  """

  require Logger

  @doc """
  Extracts plain text from a binary given its MIME type.

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  def extract(binary, content_type) when is_binary(binary) and is_binary(content_type) do
    case content_type do
      t when t in ["text/plain", "text/markdown"] ->
        {:ok, String.trim(binary)}

      "application/pdf" ->
        extract_pdf(binary)

      _ ->
        extract_via_pandoc(binary, content_type)
    end
  end

  # PDF: try pdftotext first (more reliable), fall back to pandoc
  defp extract_pdf(binary) do
    tmp_path = Path.join(System.tmp_dir!(), "xwa_extract_#{:erlang.unique_integer([:positive])}.pdf")

    try do
      File.write!(tmp_path, binary)

      case System.cmd("pdftotext", ["-layout", tmp_path, "-"], stderr_to_stdout: true) do
        {output, 0} when output != "" ->
          {:ok, String.trim(output)}

        {"", 0} ->
          Logger.warning("[TextExtractor] pdftotext returned empty output, trying pandoc")
          extract_via_pandoc_path(tmp_path, "pdf")

        {output, code} ->
          Logger.warning("[TextExtractor] pdftotext failed (code #{code}): #{String.slice(output, 0, 200)}, trying pandoc")
          extract_via_pandoc_path(tmp_path, "pdf")
      end
    rescue
      ErlangError ->
        Logger.warning("[TextExtractor] pdftotext not found, trying pandoc")
        extract_via_pandoc_path(tmp_path, "pdf")
    after
      File.rm(tmp_path)
    end
  end

  defp extract_via_pandoc(binary, content_type) do
    input_format = pandoc_input_format(content_type)

    tmp_path = Path.join(System.tmp_dir!(), "xwa_extract_#{:erlang.unique_integer([:positive])}")

    try do
      File.write!(tmp_path, binary)
      extract_via_pandoc_path(tmp_path, input_format)
    after
      File.rm(tmp_path)
    end
  end

  defp extract_via_pandoc_path(path, input_format) do
    args =
      if input_format do
        ["--from", input_format, "--to", "plain", "--wrap=none", path]
      else
        ["--to", "plain", "--wrap=none", path]
      end

    try do
      case System.cmd("pandoc", args, stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, String.trim(output)}

        {output, code} ->
          {:error, "pandoc exited with code #{code}: #{output}"}
      end
    rescue
      ErlangError -> {:error, :pandoc_not_found}
    end
  end

  @doc """
  Returns true if pdftotext is available on PATH.
  """
  def pdftotext_available? do
    case System.cmd("pdftotext", ["-v"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  @doc """
  Returns true if pandoc is available on PATH.
  """
  def available? do
    case System.cmd("pandoc", ["--version"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  rescue
    ErlangError -> false
  end

  # Map MIME types to pandoc input format identifiers.
  # nil means let pandoc auto-detect from the file extension/content.
  defp pandoc_input_format("application/vnd.openxmlformats-officedocument.wordprocessingml.document"), do: "docx"
  defp pandoc_input_format("application/vnd.oasis.opendocument.text"), do: "odt"
  defp pandoc_input_format("text/html"), do: "html"
  defp pandoc_input_format("text/markdown"), do: "markdown"
  defp pandoc_input_format("text/plain"), do: "plain"
  defp pandoc_input_format(_), do: nil
end
