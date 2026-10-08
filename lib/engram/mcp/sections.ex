defmodule Engram.MCP.Sections do
  @moduledoc """
  Markdown heading lookup shared by edit_note (replace_section,
  insert_section) and get_notes (section, outline). Pure: string in, data out.

  Where a heading is, and where its section ends, comes from a CommonMark
  parser (comrak, in `Engram.Native.md_outline/1`) with source positions, never from a hand-written
  line scanner: every scanner bug here was a silent data-loss bug, because a
  missed next heading makes replace_section overwrite the rest of the note.

  Only DOCUMENT-LEVEL headings count. A heading inside a blockquote, callout
  (`> [!note]`) or list item is content of that block, not a section
  boundary. Every parse runs through `Engram.MCP.ParseGate` (bounded
  concurrency; `opts` pass through to it), so any function here can return
  `{:error, :busy | :parse_timeout | :parse_failed | :deadline}`, or
  `{:error, :too_complex}` for a note past `outline.rs`' MAX_ITEMS headings,
  thematic breaks and code fences (the result, not the parse, would grow
  without bound). Two things CommonMark does not know about are handled before
  parsing, both preserving line numbers:

    * the frontmatter block (`Engram.Notes.Frontmatter.split/1`, the same
      rule the rest of Engram uses) is blanked out;
    * Obsidian `%% comments %%` outside code are masked to spaces (an
      unclosed `%%` hides the rest of the note, as in Obsidian).

  A leading UTF-8 BOM is ignored; line numbers index
  `String.split(content, "\\n")` and are unaffected by it.
  """

  alias Engram.MCP.ParseGate
  alias Engram.Native

  @type heading :: %{line: non_neg_integer(), level: 1..6, text: String.t(), span: pos_integer()}

  # An ATX-heading-shaped line (0-3 spaces, 1-6 `#`, then space/tab/EOL).
  # Anchored with bounded quantifiers: no backtracking blowup.
  @atx_like ~r/^ {0,3}(\#{1,6})(?:[ \t\r]|$)/

  # A setext-underline-shaped line (0-3 spaces, a run of only `=` or only
  # `-`, trailing spaces/tabs). Same bounded, anchored shape.
  @setext_like ~r/^ {0,3}(=+|-+)[ \t\r]*$/

  @type refusal :: :invalid_utf8 | :too_complex | ParseGate.error()

  @doc false
  # The whole analysis, for the golden test (test/engram/native/md_outline_test.exs).
  def outline(content), do: analyze(content, [], & &1)

  @spec headings(String.t(), keyword()) :: {:ok, [heading()]} | {:error, refusal()}
  def headings(content, opts \\ []), do: analyze(content, opts, &public(&1.headings))

  defp public(hs), do: Enum.map(hs, &Map.take(&1, [:line, :level, :text, :span]))

  @doc """
  Locates the section under `heading` (at `level`, or any level when nil).

  Matching: an exact match on the heading's RAW source text wins (first
  one); otherwise the RENDERED text (`**A**` -> "A") matches only when
  exactly one heading renders to it, and several give `{:error, :ambiguous}`.

  `hidden_heading_at` is the first line inside the section that looks like
  a heading of this level or higher but is not one in the parse, outside any
  closed code fence or closed HTML comment. Something (an unclosed block, a
  `%%` comment, a parser surprise) hid it, so `stop` may be past where the
  author thinks the section ends: writers must refuse.
  """
  @spec find(String.t(), String.t(), 1..6 | nil, keyword()) ::
          {:ok,
           %{
             start: non_neg_integer(),
             stop: non_neg_integer(),
             span: pos_integer(),
             hidden_heading_at: non_neg_integer() | nil
           }}
          | :error
          | {:error, :ambiguous | refusal()}
  def find(content, heading, level, opts \\ []) do
    with {:ok, found} <- analyze(content, opts, &locate(content, &1, heading, level, true)),
         do: found
  end

  # `hidden?` computes `hidden_heading_at`; reads (section/3) skip it.
  defp locate(content, a, heading, level, hidden?) do
    with {:ok, h} <- match(a.headings, String.trim(heading), level) do
      lines = String.split(content, "\n")
      # The section never owns the empty "line" after a trailing newline,
      # so a replace of the last section keeps the note's final newline.
      eof = if String.ends_with?(content, "\n"), do: length(lines) - 1, else: length(lines)

      stop =
        Enum.find_value(a.headings, eof, fn x ->
          x.line > h.line and x.level <= h.level and x.line
        end)

      {:ok,
       %{
         start: h.line,
         stop: stop,
         span: h.span,
         hidden_heading_at: if(hidden?, do: hidden_heading(lines, h, stop, a))
       }}
    end
  end

  defp match(hs, want, level) do
    hs = Enum.filter(hs, &(is_nil(level) or &1.level == level))

    case Enum.find(hs, &(&1.raw == want)) do
      nil ->
        case Enum.filter(hs, &(&1.text == want)) do
          [h] -> {:ok, h}
          [] -> :error
          _ -> {:error, :ambiguous}
        end

      h ->
        {:ok, h}
    end
  end

  # A line hides a heading when it is heading-shaped for this section's
  # level, the parse does not explain it (not a heading's first line or
  # setext underline at any depth, not a thematic break), and it is not in a
  # closed fence or closed HTML comment. ATX shape: the line itself. Setext
  # shape: an `=`/`-` underline directly under a non-blank line inside the
  # section; the reported line is that text line. A `---` break directly
  # under paragraph text inside a hidden region also refuses (accepted).
  # Linear: lines are visited in order and `a.safe_ranges` is sorted, so
  # the allow-list is a merge walk (was O(lines x closed fences)).
  defp hidden_heading(lines, h, stop, a) do
    from = h.line + h.span

    lines
    |> Enum.slice(from, stop - from)
    |> Enum.with_index(from)
    |> Enum.reduce_while({nil, a.safe_ranges}, fn {line, i}, {prev, safe} ->
      safe = Enum.drop_while(safe, fn {_l1, l2} -> l2 < i end)
      at = hidden_at(line, i, prev, from, h.level)

      if at && not (MapSet.member?(a.explained, i) or covered?(safe, i)),
        do: {:halt, at},
        else: {:cont, {line, safe}}
    end)
    |> then(&if(is_integer(&1), do: &1))
  end

  defp covered?([{l1, _l2} | _], i), do: l1 <= i
  defp covered?([], _i), do: false

  # Cheap prefilter: only a line whose first non-indent byte (0-3 spaces)
  # is `#`, `=` or `-` can be heading-shaped, so most lines skip the regexes.
  defp shaped?(<<" ", rest::binary>>, n) when n < 3, do: shaped?(rest, n + 1)
  defp shaped?(<<c, _::binary>>, _n) when c in [?#, ?=, ?-], do: true
  defp shaped?(_line, _n), do: false

  defp hidden_at(line, i, prev, from, level) do
    if shaped?(line, 0), do: shaped_at(line, i, prev, from, level)
  end

  defp shaped_at(line, i, prev, from, level) do
    case Regex.run(@atx_like, line) do
      [_, hashes] when byte_size(hashes) <= level ->
        i

      _ ->
        with [_, run] <- Regex.run(@setext_like, line),
             true <- i - 1 >= from and String.trim(prev || "") != "",
             true <- if(String.starts_with?(run, "="), do: 1, else: 2) <= level do
          i - 1
        else
          _ -> nil
        end
    end
  end

  # A miss returns the note's headings from the same parse, so a caller
  # listing them does not parse the note a second time.
  @spec section(String.t(), String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error, :ambiguous | refusal() | {:not_found, [heading()]}}
  def section(content, heading, opts \\ []) do
    with {:ok, located} <- analyze(content, opts, &section_at(content, &1, heading)),
         {:ok, %{start: s, stop: e}} <- located do
      text =
        content
        |> String.split("\n")
        |> Enum.slice(s, e - s)
        |> Enum.join("\n")
        |> String.trim_trailing()

      {:ok, text}
    end
  end

  defp section_at(content, a, heading) do
    case locate(content, a, heading, nil, false) do
      :error -> {:error, {:not_found, public(a.headings)}}
      other -> other
    end
  end

  # "start": directly under the heading (after the underline, for a setext
  # heading). "end": after the section's last non-blank line, so blank lines
  # before the next heading stay where they are.
  #
  # "start" never depends on `stop`, so it's unaffected by a hidden heading
  # further down; "end" does depend on it (it back-scans from `e`), so it
  # refuses rather than risk inserting past content something hid.
  @spec insert(String.t(), String.t(), 1..6, String.t(), String.t(), keyword()) ::
          {:ok, String.t()}
          | :error
          | {:error, :ambiguous | refusal() | {:hidden_heading, non_neg_integer()}}
  def insert(content, heading, level, position, text, opts \\ []) do
    with {:ok, %{start: s, stop: e, span: span} = found} <- find(content, heading, level, opts),
         :ok <- refuse_hidden(position, found) do
      lines = String.split(content, "\n")
      text = String.trim_trailing(text, "\n")

      at =
        case position do
          "start" ->
            s + span

          "end" ->
            # The heading line itself is non-blank, so this always finds one.
            back =
              lines
              |> Enum.slice(s, e - s)
              |> Enum.reverse()
              |> Enum.find_index(&(String.trim(&1) != ""))

            e - back
        end

      {lines, text} = splice_eol(lines, at, at, text, content)
      {:ok, lines |> List.insert_at(at, text) |> Enum.join("\n")}
    end
  end

  defp refuse_hidden("end", %{hidden_heading_at: l}) when is_integer(l),
    do: {:error, {:hidden_heading, l}}

  defp refuse_hidden(_position, _found), do: :ok

  # Makes `text`'s line endings match `source`'s (the note being edited).
  # Per-line, so it only ever touches the FRAGMENT being written -- never the
  # untouched lines around it, even in a note that mixes a CRLF line with LF
  # lines elsewhere.
  @spec match_eol(String.t(), String.t()) :: String.t()
  def match_eol(text, source) do
    if String.contains?(source, "\r\n") do
      text |> String.split("\n") |> Enum.map_join("\n", &(String.trim_trailing(&1, "\r") <> "\r"))
    else
      text
    end
  end

  # match_eol/2 alone assumes the fragment is always followed by more
  # content (so its own last line can safely end in "\r", relying on the
  # next line to supply the pairing "\n"). That's false exactly when the
  # fragment lands as the new end of file in a note with no trailing
  # newline: the line that WAS last never got a "\r" (nothing followed it),
  # and the fragment must not gain a stray trailing "\r" either (source had
  # no trailing newline, so neither should the result).
  #
  # `before_count` is where the fragment is inserted relative to `lines`
  # (`Enum.slice(lines, 0, before_count)` is what precedes it); `after_from`
  # is where the untouched remainder resumes (`Enum.drop(lines, after_from)`
  # -- equal to `before_count` for a pure insert with nothing removed, but
  # can be larger for a replace that removes a range).
  @spec splice_eol([String.t()], non_neg_integer(), non_neg_integer(), String.t(), String.t()) ::
          {[String.t()], String.t()}
  def splice_eol(lines, before_count, after_from, text, source) do
    if String.contains?(source, "\r\n") do
      n = length(lines)
      no_trailing_nl = not String.ends_with?(source, "\n")

      lines =
        if before_count == n and no_trailing_nl,
          do: List.update_at(lines, before_count - 1, &(&1 <> "\r")),
          else: lines

      text = match_eol(text, source)

      text =
        if after_from >= n and no_trailing_nl, do: String.trim_trailing(text, "\r"), else: text

      {lines, text}
    else
      {lines, text}
    end
  end

  # -- Parsing --

  # Invalid UTF-8 would make the NIF raise. The whole analysis AND `then`
  # (the section lookup built on it) run in the gate's task, so the slot,
  # the parse timeout and the call's deadline cover all of it, and only the
  # small result (never the AST) is copied back.
  defp analyze(content, opts, then) do
    if String.valid?(content) do
      fn ->
        case scan(content) do
          nil -> {:error, :too_complex}
          a -> {:done, then.(a)}
        end
      end
      |> ParseGate.run(Keyword.put(opts, :bytes, byte_size(content)))
      |> case do
        {:ok, {:done, result}} -> {:ok, result}
        {:ok, refused} -> refused
        error -> error
      end
    else
      {:error, :invalid_utf8}
    end
  end

  # One NIF call does all of it (`Engram.Native.md_outline/1`,
  # native/engram_native/src/outline.rs): the BOM and frontmatter, the
  # parse, the `%%`/`$$` masking, and the headings' trimmed text and raw
  # source. The rules are documented there. nil: too many headings to
  # return (see the moduledoc).
  defp scan(text) do
    case Native.md_outline(text) do
      nil -> nil
      outline -> to_analysis(outline)
    end
  end

  defp to_analysis({headings, explained, safe}) do
    %{
      headings:
        Enum.map(headings, fn {line, level, text, raw, span} ->
          %{line: line, level: level, text: text, raw: raw, span: span}
        end),
      explained: MapSet.new(explained),
      safe_ranges: safe
    }
  end
end
