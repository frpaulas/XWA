defmodule Xwa.Ingestion.DocumentSegmenter do
  @moduledoc """
  Detects whether a document contains multiple distinct voices and segments
  it into per-speaker chunks for targeted claim extraction.

  Detection is format-driven, tried in order:

    1. Congressional hearing (GPO/CRS) — delegates to HearingSegmenter
    2. Inline dialogue — lines of the form "Speaker Name: their words"
    3. Fallback — the full document as a single segment

  After the primary voice split, any segment whose text exceeds
  @subdivision_threshold chars is further split at paragraph boundaries,
  carrying the parent segment's speaker/type metadata forward onto each
  sub-segment. This prevents oversized inputs on long prepared statements,
  reports, and monologue documents while keeping attribution intact.

  All segmenters return the same ephemeral map structure:
    %{text, from_line, to_line, segment_type, speaker}

  Segment types introduced here: :dialogue_turn
  Speaker roles introduced here:  :speaker
  """

  require Logger

  alias Xwa.Ingestion.HearingSegmenter

  # Congressional hearing signatures (GPO/CRS format)
  @hearing_re ~r/OPENING STATEMENT OF HON\.|^\s{1,8}STATEMENT OF /m

  # Inline dialogue: "Speaker Name: their words" at the very start of a line.
  # Label must be 3–40 chars, begin with an uppercase letter, end with a letter,
  # and be followed by at least one non-whitespace character of content.
  @inline_re ~r/^([A-Z][A-Za-z .'\-]{1,38}[A-Za-z]):\s+\S/

  # Simple Q / A interchange (common in interview transcripts)
  @qa_simple_re ~r/^(Q|A|QUESTION|ANSWER|MODERATOR|HOST|GUEST|INTERVIEWER|INTERVIEWEE):\s+\S/i

  # Minimum speaker turns / unique speakers to accept inline dialogue
  @min_turns 3
  @min_speakers 2

  # Speaker labels must be at most this many words.
  # Prose headers like "The first problem is this" (5 words) are rejected;
  # names and titles like "Sen. Smith" or "MODERATOR" (1-3 words) pass.
  @max_label_words 4

  # Drop segments shorter than this (chars) at any stage
  @min_segment_chars 100

  # Segments longer than this are further subdivided at paragraph boundaries.
  # ~8 000 chars ≈ 2 000 tokens — keeps Claude focused and avoids max_tokens exhaustion.
  @subdivision_threshold 8_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Segments `text` into speaker-attributed, size-bounded chunks.
  Returns a non-empty list of segment maps (at least one).
  """
  @spec segment(String.t()) :: [map()]
  def segment(text) do
    primary_segments =
      cond do
        hearing?(text) ->
          Logger.info("[DocumentSegmenter] Detected congressional hearing format")
          HearingSegmenter.segment(text)

        segments = try_inline_dialogue(text) ->
          Logger.info("[DocumentSegmenter] Detected inline dialogue (#{length(segments)} segments)")
          segments

        true ->
          Logger.debug("[DocumentSegmenter] No multi-speaker structure detected — single segment")
          [fallback(text)]
      end

    result = Enum.flat_map(primary_segments, &subdivide_if_long/1)

    Logger.info("[DocumentSegmenter] Final segment count: #{length(result)}")
    result
  end

  # ---------------------------------------------------------------------------
  # Format detection
  # ---------------------------------------------------------------------------

  defp hearing?(text), do: Regex.match?(@hearing_re, text)

  # ---------------------------------------------------------------------------
  # Inline dialogue segmenter
  # ---------------------------------------------------------------------------

  defp try_inline_dialogue(text) do
    indexed = text |> String.split("\n") |> Enum.with_index(1)

    turns =
      Enum.flat_map(indexed, fn {line, n} ->
        cond do
          m = Regex.run(@qa_simple_re, line, capture: :all_but_first) ->
            [{n, String.upcase(hd(m))}]

          m = Regex.run(@inline_re, line, capture: :all_but_first) ->
            label = hd(m)
            if label_word_count(label) <= @max_label_words, do: [{n, label}], else: []

          true ->
            []
        end
      end)

    unique_labels = turns |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    # Require at least one speaker to appear more than once — all-unique labels
    # indicate prose headers, not real dialogue turns.
    label_counts = Enum.frequencies(Enum.map(turns, &elem(&1, 1)))
    has_repeat_speaker = Enum.any?(label_counts, fn {_, count} -> count >= 2 end)

    if length(turns) >= @min_turns and length(unique_labels) >= @min_speakers and has_repeat_speaker do
      build_inline_segments(indexed, turns)
    end
  end

  defp build_inline_segments(indexed, turns) do
    total_lines = length(indexed)
    line_map = Map.new(indexed, fn {line, n} -> {n, line} end)

    segments =
      turns
      |> Enum.with_index()
      |> Enum.flat_map(fn {{from, label}, i} ->
        next_start =
          case Enum.at(turns, i + 1) do
            nil -> total_lines + 1
            {nl, _} -> nl
          end

        text =
          from..(next_start - 1)
          |> Enum.map(&Map.get(line_map, &1, ""))
          |> Enum.join("\n")
          |> String.trim()

        if String.length(text) >= @min_segment_chars do
          [%{
            text: text,
            from_line: from,
            to_line: next_start - 1,
            segment_type: :dialogue_turn,
            speaker: %{name: label, role: :speaker, affiliation: nil}
          }]
        else
          []
        end
      end)

    if length(segments) >= @min_turns, do: segments
  end

  # ---------------------------------------------------------------------------
  # Paragraph-level subdivision
  # Applied to every segment after the primary voice split.
  # Segments under threshold pass through unchanged.
  # ---------------------------------------------------------------------------

  defp subdivide_if_long(%{text: text} = seg) when byte_size(text) <= @subdivision_threshold do
    [seg]
  end

  defp subdivide_if_long(%{text: text, from_line: base_line} = seg) do
    paragraphs =
      text
      |> String.split(~r/\n{2,}/, trim: true)
      |> Enum.reject(&(String.trim(&1) == ""))

    chunks = group_into_chunks(paragraphs, @subdivision_threshold)

    # Estimate from_line / to_line for each chunk by counting newlines
    {result, _} =
      Enum.reduce(chunks, {[], 0}, fn chunk, {acc, lines_consumed} ->
        chunk_line_count = chunk |> String.split("\n") |> length()

        from = if base_line, do: base_line + lines_consumed, else: nil
        to   = if from,      do: from + chunk_line_count - 1, else: nil

        new_seg = %{seg | text: chunk, from_line: from, to_line: to}
        # +2 accounts for the blank-line separator between paragraphs
        {[new_seg | acc], lines_consumed + chunk_line_count + 2}
      end)

    result
    |> Enum.reverse()
    |> Enum.reject(&(String.length(String.trim(&1.text)) < @min_segment_chars))
    |> case do
      [] -> [seg]   # paranoia: never drop everything
      segs -> segs
    end
  end

  # Greedily pack paragraphs into chunks not exceeding `threshold` chars.
  # A single paragraph that exceeds the threshold on its own forms its own chunk.
  defp group_into_chunks(paragraphs, threshold) do
    {chunks, last} =
      Enum.reduce(paragraphs, {[], []}, fn para, {done, current} ->
        candidate = if current == [], do: para, else: Enum.join(current, "\n\n") <> "\n\n" <> para

        if String.length(candidate) > threshold and current != [] do
          {[Enum.join(current, "\n\n") | done], [para]}
        else
          {done, current ++ [para]}
        end
      end)

    (if last == [], do: chunks, else: [Enum.join(last, "\n\n") | chunks])
    |> Enum.reverse()
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp label_word_count(label) do
    label |> String.split(~r/\s+/, trim: true) |> length()
  end

  # ---------------------------------------------------------------------------
  # Fallback
  # ---------------------------------------------------------------------------

  defp fallback(text) do
    %{text: text, from_line: nil, to_line: nil, segment_type: nil, speaker: nil}
  end
end
