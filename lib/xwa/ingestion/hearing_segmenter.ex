defmodule Xwa.Ingestion.HearingSegmenter do
  @moduledoc """
  Segments a Congressional hearing transcript (GPO/CRS format) into
  per-speaker/per-section chunks for targeted claim extraction.

  Segments are ephemeral maps — never persisted. Each carries:
    - text:         the speaker's contribution, ready for claim extraction
    - from_line:    first line in the source document
    - to_line:      last line in the source document
    - segment_type: :opening_statement | :witness_statement | :qa_turn
    - speaker:      %{name, role, affiliation} or nil

  Speaker roles: :chair | :ranking_member | :witness | :member

  The segmenter is a line-by-line state machine. States:
    :preamble   — header/roster/TOC, discarded
    :opening    — a member opening statement
    :witness    — a witness oral statement
    :qa         — Q&A dialogue, one turn per speaker
    :between    — gap after prepared statement stub, waiting for next section
    :done       — after submitted materials, nothing more to process
  """

  require Logger

  # ---------------------------------------------------------------------------
  # Structural markers (GPO/CRS transcript conventions)
  # ---------------------------------------------------------------------------

  # "OPENING STATEMENT OF HON. BRETT GUTHRIE, A REPRESENTATIVE..."
  @opening_re ~r/^OPENING STATEMENT OF HON\.\s+(.+)/

  # "                STATEMENT OF ERIC SCHMIDT, Ph.D."  (indented 1–8 spaces)
  @witness_re ~r/^\s{1,8}STATEMENT OF (.+)/

  # "    Mr. Guthrie. " / "    Dr. Schmidt. " / "    Ms. Ocasio-Cortez. "
  # Also handles "Carter of Georgia" disambiguators
  @qa_turn_re ~r/^\s{2,6}(Mr|Mrs|Ms|Dr)\.\s+([A-Z][a-zA-Z\-']+(?:\s+of\s+[A-Z][a-z]+)?)\.\s/

  # "[The prepared statement of X follows:]" — end of oral section, stub only
  @prepared_stub_re ~r/\[The prepared statement of .+ follows:\]/i

  # Signals end of hearing proper
  @submitted_re ~r/Inclusion of the following was approved by unanimous consent/i

  # Lines to silently skip
  @skip_re ~r/\[GRAPHIC/

  # Minimum chars for a segment to be worth processing
  @min_segment_chars 100

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Splits hearing transcript text into speaker-attributed segments.
  Returns a list of segment maps with provenance metadata.
  """
  @spec segment(String.t()) :: [map()]
  def segment(text) do
    indexed = text |> String.split("\n") |> Enum.with_index(1)
    speaker_map = build_speaker_map(indexed)
    segments = run_state_machine(indexed, speaker_map)
    Logger.info("[HearingSegmenter] Produced #{length(segments)} segments from #{length(indexed)} lines")
    segments
  end

  # ---------------------------------------------------------------------------
  # Speaker map
  # Build a %{"LastName" => %{name, role, affiliation}} lookup from
  # the statement headers encountered in the document.
  # First OPENING STATEMENT = chair, second = ranking_member, rest = member.
  # STATEMENT OF headers yield witnesses.
  # ---------------------------------------------------------------------------

  defp build_speaker_map(indexed) do
    plain = Enum.map(indexed, &elem(&1, 0))

    {member_map, _idx} =
      plain
      |> Enum.reduce({%{}, 0}, fn line, {map, idx} ->
        case Regex.run(@opening_re, line) do
          [_, name_raw] ->
            role = case idx do
              0 -> :chair
              1 -> :ranking_member
              _ -> :member
            end
            entry = opening_to_speaker(name_raw, role)
            {Map.put(map, entry.last_name, Map.delete(entry, :last_name)), idx + 1}

          _ ->
            {map, idx}
        end
      end)

    witness_map =
      plain
      |> Enum.flat_map(fn line ->
        case Regex.run(@witness_re, line) do
          [_, name_raw] ->
            s = witness_to_speaker(name_raw)
            [{s.last_name, Map.delete(s, :last_name)}]
          _ ->
            []
        end
      end)
      |> Map.new()

    Map.merge(member_map, witness_map)
  end

  defp opening_to_speaker(raw, role) do
    # "HON. BRETT GUTHRIE, A REPRESENTATIVE IN CONGRESS FROM THE COMMONWEALTH OF KENTUCKY"
    # Extract name (before first comma) and state (after "FROM THE ... OF ")
    name =
      raw
      |> String.split(",")
      |> List.first()
      |> String.replace(~r/\bHON\.\s*/i, "")
      |> String.trim()
      |> titlecase()

    affiliation =
      case Regex.run(~r/FROM THE (?:STATE|COMMONWEALTH|TERRITORY) OF (.+)/i, raw) do
        [_, state] -> String.trim(state)
        _ -> nil
      end

    last = name |> String.split() |> List.last()
    %{last_name: last, name: name, role: role, affiliation: affiliation}
  end

  defp witness_to_speaker(raw) do
    # "ERIC SCHMIDT, Ph.D." or "MANISH BHATIA"
    raw = String.trim(raw)
    name = raw |> String.split(",") |> List.first() |> String.trim() |> titlecase()
    last = name |> String.split() |> List.last()
    %{last_name: last, name: name, role: :witness, affiliation: nil}
  end

  defp titlecase(str) do
    str
    |> String.split()
    |> Enum.map(fn w ->
      # Preserve all-caps abbreviations like "Ph.D." but capitalise plain words
      if Regex.match?(~r/^[A-Z]+\.$/, w), do: w, else: String.capitalize(w)
    end)
    |> Enum.join(" ")
  end

  # ---------------------------------------------------------------------------
  # State machine
  # ---------------------------------------------------------------------------

  defp run_state_machine(indexed, speaker_map) do
    last_line = indexed |> List.last() |> elem(1)

    initial = %{
      mode: :preamble,
      segment_type: nil,
      speaker: nil,
      start_line: nil,
      buffer: [],
      segments: []
    }

    final =
      Enum.reduce(indexed, initial, fn {line, n}, state ->
        cond do
          state.mode == :done ->
            state

          String.match?(line, @submitted_re) ->
            state |> emit(n - 1) |> Map.put(:mode, :done)

          String.match?(line, @skip_re) ->
            state

          # Prepared statement stub — close current segment, enter :between
          String.match?(line, @prepared_stub_re) ->
            state |> emit(n - 1) |> Map.merge(%{mode: :between, buffer: []})

          # Opening statement header
          m = Regex.run(@opening_re, line) ->
            [_, name_raw] = m
            speaker = resolve_speaker(last_word(name_raw), name_raw, :member, speaker_map)
            state |> emit(n - 1) |> start(:opening, :opening_statement, speaker, n)

          # Witness statement header
          m = Regex.run(@witness_re, line) ->
            [_, name_raw] = m
            speaker = resolve_speaker(last_word(name_raw), name_raw, :witness, speaker_map)
            state |> emit(n - 1) |> start(:witness, :witness_statement, speaker, n)

          # Q&A turn (works in any mode except :preamble and :done)
          state.mode != :preamble ->
            case Regex.run(@qa_turn_re, line) do
              [_, _title, name_part] ->
                speaker = resolve_speaker(last_word(name_part), name_part, :member, speaker_map)
                state |> emit(n - 1) |> start(:qa, :qa_turn, speaker, n) |> accum(line)

              nil ->
                if state.mode == :between, do: state, else: accum(state, line)
            end

          true ->
            state
        end
      end)

    final
    |> emit(last_line)
    |> Map.get(:segments)
    |> Enum.reverse()
    |> Enum.reject(&short?/1)
  end

  defp start(state, mode, segment_type, speaker, line_no) do
    %{state | mode: mode, segment_type: segment_type, speaker: speaker, start_line: line_no, buffer: []}
  end

  defp accum(state, line), do: %{state | buffer: [line | state.buffer]}

  defp emit(%{start_line: nil} = state, _to), do: state
  defp emit(%{mode: m} = state, _to) when m in [:preamble, :between, :done], do: %{state | buffer: []}

  defp emit(state, to_line) do
    text = state.buffer |> Enum.reverse() |> Enum.join("\n") |> String.trim()

    seg = %{
      text: text,
      from_line: state.start_line,
      to_line: to_line,
      segment_type: state.segment_type,
      speaker: state.speaker
    }

    %{state | segments: [seg | state.segments], buffer: [], start_line: nil}
  end

  # ---------------------------------------------------------------------------
  # Speaker resolution
  # ---------------------------------------------------------------------------

  defp resolve_speaker(last_name, raw, default_role, speaker_map) do
    case Map.get(speaker_map, last_name) do
      nil ->
        name = raw |> String.split(",") |> List.first() |> String.trim() |> titlecase()
        %{name: name, role: default_role, affiliation: nil}
      entry ->
        entry
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Last word of a name phrase — used as lookup key in speaker_map
  defp last_word(str) do
    str
    |> String.split(~r/[,\s]+/)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> then(&(String.capitalize(&1 || "")))
  end

  defp short?(%{text: t}), do: String.length(t) < @min_segment_chars
  defp short?(_), do: true
end
