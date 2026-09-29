defmodule Engram.MCP.Sections do
  @moduledoc """
  Markdown heading lookup shared by edit_note (replace_section,
  insert_section) and get_notes (section, outline). Pure: string in, data out.

  Where a heading is, and where its section ends, comes from a CommonMark
  parser (comrak, via the mdex_native NIF) with source positions, never from a hand-written
  line scanner: every scanner bug here was a silent data-loss bug, because a
  missed next heading makes replace_section overwrite the rest of the note.

  Only DOCUMENT-LEVEL headings count. A heading inside a blockquote, callout
  (`> [!note]`) or list item is content of that block, not a section
  boundary. Every parse runs through `Engram.MCP.ParseGate` (bounded
  concurrency; `opts` pass through to it), so any function here can return
  `{:error, :busy | :parse_timeout | :parse_failed | :deadline}`. Two things CommonMark does not know about are handled before
  parsing, both preserving line numbers:

    * the frontmatter block (`Engram.Notes.Frontmatter.split/1`, the same
      rule the rest of Engram uses) is blanked out;
    * Obsidian `%% comments %%` outside code are masked to spaces (an
      unclosed `%%` hides the rest of the note, as in Obsidian).

  A leading UTF-8 BOM is ignored; line numbers index
  `String.split(content, "\\n")` and are unaffected by it.
  """

  alias Engram.MCP.ParseGate
  alias Engram.Notes.Frontmatter

  @type heading :: %{line: non_neg_integer(), level: 1..6, text: String.t(), span: pos_integer()}

  @bom "﻿"

  # GFM tables (so a delimiter row is never a setext underline) and
  # strikethrough (heading text), matching what Obsidian renders. Raw HTML
  # stays at the CommonMark default. Frontmatter is NOT comrak's
  # front_matter_delimiter: Frontmatter.split/1 is Engram's one definition of
  # it (CRLF fences included), so it is blanked out before parsing instead.
  @parse_opts [extension: [table: true, strikethrough: true]]

  # An ATX-heading-shaped line (0-3 spaces, 1-6 `#`, then space/tab/EOL).
  # Anchored with bounded quantifiers: no backtracking blowup.
  @atx_like ~r/^ {0,3}(\#{1,6})(?:[ \t\r]|$)/

  # A setext-underline-shaped line (0-3 spaces, a run of only `=` or only
  # `-`, trailing spaces/tabs). Same bounded, anchored shape.
  @setext_like ~r/^ {0,3}(=+|-+)[ \t\r]*$/

  @type refusal :: :invalid_utf8 | ParseGate.error()

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
      ParseGate.run(
        fn ->
          content |> String.replace_prefix(@bom, "") |> blank_frontmatter() |> scan() |> then.()
        end,
        Keyword.put(opts, :bytes, byte_size(content))
      )
    else
      {:error, :invalid_utf8}
    end
  end

  # Replaces the frontmatter block with the same number of empty lines.
  defp blank_frontmatter(text) do
    case Frontmatter.split(text) do
      {nil, _body} ->
        text

      {_block, body} ->
        prefix = binary_part(text, 0, byte_size(text) - byte_size(body))
        String.duplicate("\n", length(:binary.matches(prefix, "\n"))) <> body
    end
  end

  # `text` must already be free of BOM and frontmatter. One parse, plus one
  # more only when `%%` comments or `$$` math blocks had to be masked.
  defp scan(text) do
    # CommonMark also ends a line at a lone "\r"; callers count lines by
    # "\n" only, so a lone "\r" becomes a space (same byte offsets).
    text = String.replace(text, ~r/\r(?!\n)/, " ")
    starts = line_starts(text)
    {doc, math} = mask_obsidian(text, starts, parse(text))
    {explained, safe_ranges} = walk(doc, {MapSet.new(), math})

    %{
      headings:
        for(%MDExNative.Comrak.Heading{} = h <- doc.nodes, do: to_heading(h, text, starts)),
      explained: explained,
      safe_ranges: Enum.sort(safe_ranges)
    }
  end

  defp parse(text), do: MDExNative.Comrak.parse_document(text, @parse_opts)

  defp to_heading(
         %MDExNative.Comrak.Heading{sourcepos: %{start: {l1, _}, end: {l2, _}}} = h,
         text,
         starts
       ) do
    %{
      line: l1 - 1,
      level: h.level,
      text: String.trim(plain_text(h.nodes)),
      raw: raw_text(h, text, starts),
      span: l2 - l1 + 1
    }
  end

  # The heading's inline content exactly as written (`**A**`, `a &amp; b`,
  # `\#x`): from the heading's own start (past the opening `#`s for ATX) to
  # the last inline node's end, so no closing `#`s. Not from the FIRST inline
  # node's start: comrak starts a leading escape's text after the backslash.
  # A multi-line setext heading's lines are trimmed and joined with a space,
  # the same way its rendered text is.
  defp raw_text(%MDExNative.Comrak.Heading{nodes: []}, _text, _starts), do: ""

  defp raw_text(%MDExNative.Comrak.Heading{sourcepos: %{start: {l1, c1}}} = h, text, starts) do
    %{sourcepos: %{end: {l2, c2}}} = List.last(h.nodes)
    from = elem(starts, l1 - 1) + c1 - 1
    to = elem(starts, l2 - 1) + c2
    raw = text |> binary_part(from, to - from) |> String.trim_leading()
    raw = if h.setext, do: raw, else: binary_part(raw, h.level, byte_size(raw) - h.level)

    raw
    |> String.split("\n")
    |> Enum.map_join(" ", &String.trim/1)
    |> String.trim()
  end

  # Inline markup rendered to its text: `**B**` -> "B", `[l](u)` -> "l",
  # a code span -> its content, a soft/hard break -> " ". Raw inline HTML
  # keeps its literal (it is part of what the reader sees in the source).
  defp plain_text(nodes) do
    Enum.map_join(nodes, fn
      %{literal: lit} -> lit
      %MDExNative.Comrak.SoftBreak{} -> " "
      %MDExNative.Comrak.LineBreak{} -> " "
      %{nodes: children} -> plain_text(children)
      _ -> ""
    end)
  end

  # `explained`: lines the parse accounts for that are heading-SHAPED
  # without being hidden: every heading's first line and (setext) underline
  # at ANY depth (a nested heading is a heading, just not a section
  # boundary), and every thematic break. `safe`: 0-indexed line ranges of
  # CLOSED fenced code blocks and CLOSED HTML comment blocks (plus the masked
  # `$$` math blocks, seeded by scan/1), the only places a heading-shaped
  # line may legitimately sit hidden inside a section.
  defp walk(
         %MDExNative.Comrak.Heading{sourcepos: %{start: {l1, _}, end: {l2, _}}} = h,
         {ex, safe}
       ),
       do: walk_children(h, {ex |> MapSet.put(l1 - 1) |> MapSet.put(l2 - 1), safe})

  defp walk(%MDExNative.Comrak.ThematicBreak{sourcepos: %{start: {l, _}}}, {ex, safe}),
    do: {MapSet.put(ex, l - 1), safe}

  defp walk(%MDExNative.Comrak.CodeBlock{fenced: true, closed: true, sourcepos: sp}, {ex, safe}),
    do: {ex, [range(sp) | safe]}

  defp walk(%MDExNative.Comrak.HtmlBlock{block_type: 2, literal: lit, sourcepos: sp}, {ex, safe}) do
    if String.contains?(lit, "-->"), do: {ex, [range(sp) | safe]}, else: {ex, safe}
  end

  # Any other node, known or not (a future node type included): recurse into
  # its children, so a heading nested anywhere is still seen.
  defp walk(node, acc), do: walk_children(node, acc)

  defp walk_children(%{nodes: nodes}, acc), do: Enum.reduce(nodes, acc, &walk/2)
  defp walk_children(_node, acc), do: acc

  defp range(%{start: {l1, _}, end: {l2, _}}), do: {l1 - 1, l2 - 1}

  # Obsidian syntax CommonMark does not know, masked to spaces (newlines
  # kept, so lines and byte offsets do not move) before ONE re-parse. Code
  # (code blocks and inline code spans) comes from the first parse; neither
  # construct is recognized inside it. Returns the doc and the 0-indexed
  # line ranges of the masked math blocks (closed, so allow-listed like a
  # closed fence).
  #
  #   * `%%` comments: every `%%` outside code toggles a comment; an
  #     unclosed `%%` hides everything after it.
  #   * `$$` display math: a line that is exactly `$$` (trimmed) opens a
  #     block, the next such line closes it. Its lines are TeX, not markdown
  #     (a `## x` inside is no heading). An unpaired `$$` is left alone.
  #     comrak's math_dollars extension does not help: it parses `$$` as
  #     INLINE math, after block structure has already made `## x` a heading.
  #
  # ponytail: one pass. Code spans come from the UNmasked parse, so a
  # backtick inside a `%%` comment can pair with one after it and mis-pair
  # later `%%`s. find/4's hidden-heading check turns that into a refused
  # write rather than a wrong section; a fixed-point loop would fix the read.
  defp mask_obsidian(text, starts, doc) do
    pct = :binary.matches(text, "%%")
    dollars = :binary.matches(text, "$$")

    if pct == [] and dollars == [] do
      {doc, []}
    else
      code = doc |> code_ranges(starts, []) |> Enum.reverse()
      marks = pct |> Enum.map(&elem(&1, 0)) |> outside(code, [])
      masked = if marks == [], do: text, else: mask(text, marks)
      math = math_blocks(masked, starts, dollars, code)
      masked = blank_lines(masked, starts, math)

      if masked == text, do: {doc, []}, else: {parse(masked), math}
    end
  end

  # [{open_line, close_line}] for `$$` lines outside code, paired in order.
  defp math_blocks(text, starts, dollars, code) do
    dollars
    |> Enum.map(&elem(&1, 0))
    |> outside(code, [])
    |> Enum.map(&line_of(starts, &1))
    |> Enum.dedup()
    |> Enum.filter(&(line_text(text, starts, &1) |> String.trim() == "$$"))
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.map(fn [open, close] -> {open, close} end)
  end

  defp line_text(text, starts, l) do
    from = elem(starts, l)
    to = if l + 1 < tuple_size(starts), do: elem(starts, l + 1) - 1, else: byte_size(text)
    binary_part(text, from, to - from)
  end

  # Blanks whole line ranges in ONE pass (ranges sorted, disjoint).
  defp blank_lines(text, _starts, []), do: text

  defp blank_lines(text, starts, ranges) do
    {parts, pos} =
      Enum.reduce(ranges, {[], 0}, fn {l1, l2}, {acc, pos} ->
        from = elem(starts, l1)
        to = if l2 + 1 < tuple_size(starts), do: elem(starts, l2 + 1) - 1, else: byte_size(text)

        {[blank(binary_part(text, from, to - from)), binary_part(text, pos, from - pos) | acc],
         to}
      end)

    IO.iodata_to_binary(Enum.reverse([binary_part(text, pos, byte_size(text) - pos) | parts]))
  end

  # Line of a byte offset: binary search over the line-start offsets.
  defp line_of(starts, offset), do: line_of(starts, offset, 0, tuple_size(starts) - 1)

  defp line_of(_starts, _offset, lo, hi) when lo >= hi, do: lo

  defp line_of(starts, offset, lo, hi) do
    mid = div(lo + hi + 1, 2)

    if elem(starts, mid) <= offset,
      do: line_of(starts, offset, mid, hi),
      else: line_of(starts, offset, lo, mid - 1)
  end

  # Byte offset of the start of each line (0-indexed line -> offset).
  defp line_starts(text) do
    [0 | for({at, _} <- :binary.matches(text, "\n"), do: at + 1)] |> List.to_tuple()
  end

  # [{from, to}] byte ranges (to exclusive) of code, in document order.
  # sourcepos columns are 1-based BYTE columns.
  defp code_ranges(
         %MDExNative.Comrak.CodeBlock{sourcepos: %{start: {l1, _}, end: {l2, _}}},
         starts,
         acc
       ) do
    to = if l2 < tuple_size(starts), do: elem(starts, l2), else: :infinity
    [{elem(starts, l1 - 1), to} | acc]
  end

  defp code_ranges(
         %MDExNative.Comrak.Code{sourcepos: %{start: {l1, c1}, end: {l2, c2}}},
         starts,
         acc
       ) do
    [{elem(starts, l1 - 1) + c1 - 1, elem(starts, l2 - 1) + c2} | acc]
  end

  defp code_ranges(%{nodes: nodes}, starts, acc),
    do: Enum.reduce(nodes, acc, &code_ranges(&1, starts, &2))

  defp code_ranges(_node, _starts, acc), do: acc

  # Both lists are sorted: a merge walk, O(matches + ranges).
  defp outside([], _code, acc), do: Enum.reverse(acc)
  defp outside(ms, [{_from, to} | code], acc) when hd(ms) >= to, do: outside(ms, code, acc)
  defp outside([m | ms], [{from, _} | _] = code, acc) when m >= from, do: outside(ms, code, acc)
  defp outside([m | ms], code, acc), do: outside(ms, code, [m | acc])

  # Pairs the marks (open, close, open, close, ...) and blanks each pair,
  # delimiters included. An odd mark out blanks to EOF.
  defp mask(text, marks), do: mask(text, marks, 0, [])

  defp mask(text, [open, close | rest], pos, acc) do
    acc = [
      blank(binary_part(text, open, close + 2 - open)),
      binary_part(text, pos, open - pos) | acc
    ]

    mask(text, rest, close + 2, acc)
  end

  defp mask(text, [open], pos, acc) do
    tail = binary_part(text, open, byte_size(text) - open)

    IO.iodata_to_binary(Enum.reverse([blank(tail), binary_part(text, pos, open - pos) | acc]))
  end

  defp mask(text, [], pos, acc) do
    IO.iodata_to_binary(Enum.reverse([binary_part(text, pos, byte_size(text) - pos) | acc]))
  end

  defp blank(part) do
    part
    |> String.split("\n")
    |> Enum.map_intersperse("\n", &String.duplicate(" ", byte_size(&1)))
  end
end
