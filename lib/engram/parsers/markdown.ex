defmodule Engram.Parsers.Markdown do
  @moduledoc """
  Heading-aware markdown chunker.

  Splits content at heading boundaries, builds folder-aware context prefixes,
  and sub-chunks large sections at word boundaries (~512 tokens / 2048 chars).
  """

  alias Engram.Notes.Helpers

  # ~4 chars per token; 512 tokens ≈ 2048 chars
  @max_chunk_chars 2048
  @max_prefix_bytes 512

  @doc """
  Parse markdown content into indexable chunks.

  Returns a list of chunk maps:
  - `:position`     — sequential index (0-based)
  - `:text`         — raw chunk text (no context prefix)
  - `:context_text` — "folder > title > heading\\n\\ntext" for embedding
  - `:heading_path` — e.g. "Title > H1 > H2"
  - `:char_start`   — byte offset in post-frontmatter body
  - `:char_end`     — byte offset end

  Exception: when frontmatter is present, a synthetic chunk carrying the raw
  frontmatter block is appended last, with `heading_path` fixed to
  `"frontmatter"` and `char_start`/`char_end` both fixed to `0`.
  """
  def parse("", _path), do: []

  def parse(content, path) do
    # The frontmatter codec and the heading patterns all expect LF, so a CRLF
    # note lost its frontmatter chunk and had its body cut short (#1605).
    content = String.replace(content, "\r\n", "\n")
    folder = extract_folder(path)
    title = Helpers.extract_title(content, path)
    body = strip_frontmatter(content)

    body_chunks =
      if String.trim(body) == "" do
        []
      else
        body
        |> split_into_sections(title)
        |> build_chunks(folder, title)
      end

    (body_chunks ++ frontmatter_chunk(content, folder, title))
    |> Enum.flat_map(&enforce_size_cap/1)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, idx} -> Map.put(chunk, :position, idx) end)
  end

  # ---------------------------------------------------------------------------
  # Size cap (backstop)
  # ---------------------------------------------------------------------------

  # Every chunk's `context_text` is sent to Voyage, which rejects an oversized
  # input with a permanent HTTP 400 — no retry fixes it, so EmbedNote parks the
  # note on a 6h poison cooldown and ReconcileEmbeddings re-tries it forever
  # (prod, 2026-09-09: six notes from one import, stuck).
  #
  # Two paths above emit unbounded text: `split_text/2` splits on spaces, so a
  # run with none (base64 data URI, long URL, minified blob, CJK) passes through
  # whole; and `frontmatter_chunk/3` never consulted a limit at all. Capping here
  # rather than in each one means every chunk — including any a future path adds
  # — flows through a single limit.
  #
  # The cap covers `context_text`, NOT just `text`, and that distinction is the
  # whole point: `text` is never what gets embedded. Bounding only `text` left
  # the prefix — `folder > title > heading_path`, built from a `.+` match on one
  # heading line and truncated nowhere — free to be arbitrary. A note whose H1
  # is a 200KB pasted blob gave every one of its 99 chunks a 202KB
  # `context_text` with a correctly-capped 2048-byte `text`, so each shipped as
  # its own oversized single-input batch and 400'd on both the per-input and
  # per-request token limits. Same poison loop, one field to the left.
  defp enforce_size_cap(%{text: text, context_text: context_text} = chunk)
       when byte_size(text) <= @max_chunk_chars and
              byte_size(context_text) - byte_size(text) <= @max_prefix_bytes do
    [chunk]
  end

  defp enforce_size_cap(chunk) do
    prefix = chunk |> context_prefix_of() |> cap_prefix()

    chunk.text
    |> hard_split(@max_chunk_chars)
    |> Enum.map(&%{chunk | text: &1, context_text: prefix <> &1})
  end

  # A prefix is a breadcrumb, so 512 bytes is already far past any real
  # `folder > title > h1 > h2`; anything longer is a pathological heading, not
  # context worth keeping. Truncation goes through `hard_split/2` for the same
  # reason the text cap does — a raw `binary_part` would halve a multibyte
  # character, and CJK headings are exactly the input that reaches here.
  #
  # The separator is re-appended because `context_prefix_of/1` returns the
  # prefix WITH its trailing "\n\n", which the truncation cuts off.
  defp cap_prefix(prefix) when byte_size(prefix) <= @max_prefix_bytes, do: prefix

  defp cap_prefix(prefix) do
    (prefix |> hard_split(@max_prefix_bytes) |> hd()) <> "\n\n"
  end

  # Both construction sites build `context_text` as
  # `context_prefix <> "\n\n" <> text`, so the leading bytes that are not the
  # text are exactly the prefix plus its separator — reusable as-is.
  #
  # Checked rather than assumed. This cap exists to hold for paths that do not
  # exist yet, and a subtraction on a path that builds `context_text` some
  # other way goes negative and raises inside the parser — which fails the
  # embed, which lands us back in the poison loop the cap is here to prevent.
  # Losing a prefix degrades one chunk's context; raising breaks the note.
  defp context_prefix_of(%{context_text: context_text, text: text}) do
    if String.ends_with?(context_text, text) do
      binary_part(context_text, 0, byte_size(context_text) - byte_size(text))
    else
      ""
    end
  end

  # Split at codepoint boundaries into pieces of at most `max_bytes`. Slicing at
  # a raw byte offset would cut a multibyte character in half and yield invalid
  # UTF-8 — and space-free multibyte text (CJK) is precisely the input that gets
  # here, since it offers the word splitter nothing to split on.
  # Slices the binary rather than walking `String.codepoints/1`. Materialising
  # one binary per character costs ~17s of CPU on a 10MB note (measured), and
  # this runs in an Oban worker at concurrency 5 — the shape of the embed OOM
  # in #891. Slicing yields sub-binary references and no per-character garbage.
  defp hard_split(text, max_bytes), do: hard_split(text, max_bytes, [])

  defp hard_split(text, max_bytes, acc) when byte_size(text) <= max_bytes do
    Enum.reverse([text | acc])
  end

  defp hard_split(text, max_bytes, acc) do
    cut = codepoint_boundary(text, max_bytes)
    <<piece::binary-size(cut), rest::binary>> = text
    hard_split(rest, max_bytes, [piece | acc])
  end

  # Walk back while the cut points INTO a character. UTF-8 continuation bytes
  # are 0b10xxxxxx, so this is at most 3 steps on valid input.
  #
  # Backing all the way to 0 means the whole window is continuation bytes —
  # only reachable on invalid UTF-8, where there is no boundary to find. Take
  # one byte rather than loop forever: the parser must not be what breaks a
  # note. Losslessness is unaffected either way, since this only ever slices.
  defp codepoint_boundary(text, offset) when offset > 0 do
    if continuation_byte?(text, offset),
      do: codepoint_boundary(text, offset - 1),
      else: offset
  end

  defp codepoint_boundary(_text, _offset), do: 1

  defp continuation_byte?(text, offset) do
    case text do
      <<_::binary-size(offset), byte, _::binary>> -> byte in 0x80..0xBF
      _ -> false
    end
  end

  # Frontmatter values used to be stripped before indexing, making every key
  # invisible to keyword search (spec 2026-07-02). One synthetic chunk carries
  # the raw block into the BM25 leg. char offsets are 0/0: the block sits
  # before the post-frontmatter body that offsets are relative to.
  defp frontmatter_chunk(content, folder, title) do
    case Engram.Notes.Frontmatter.split(content) do
      {block, _body} when is_binary(block) and block != "" ->
        context_prefix = build_context_prefix(folder, "#{title} > frontmatter")

        [
          %{
            text: block,
            context_text: context_prefix <> "\n\n" <> block,
            heading_path: "frontmatter",
            char_start: 0,
            char_end: 0
          }
        ]

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Frontmatter
  # ---------------------------------------------------------------------------

  # The same split `frontmatter_chunk/3` uses, so the body and the frontmatter
  # chunk always agree on where the block ends. The regex this replaced took a
  # BYTE length and sliced by GRAPHEME, so each multibyte character in the
  # frontmatter cut one more from the start of the body, and it missed a
  # closing fence at EOF that the split accepts, indexing that block twice.
  defp strip_frontmatter(content) do
    {_block, body} = Engram.Notes.Frontmatter.split(content)
    body
  end

  # ---------------------------------------------------------------------------
  # Section splitting
  # ---------------------------------------------------------------------------

  # Returns [{heading_stack, text, char_start, char_end}]
  defp split_into_sections(body, _title) do
    heading_re = ~r/^(\#{1,6})\s+(.+)$/m

    lines = String.split(body, "\n")

    {sections, last_section, _offset} =
      Enum.reduce(lines, {[], %{heading_stack: [], lines: [], char_start: 0}, 0}, fn line,
                                                                                     {done,
                                                                                      current,
                                                                                      pos} ->
        # +1 for the \n we split on
        line_len = byte_size(line) + 1

        case Regex.run(heading_re, line, capture: :all_but_first) do
          [hashes, text] ->
            level = String.length(hashes)
            # Flush current section
            done =
              if current.lines != [] do
                section_text = current.lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()

                if section_text != "" do
                  end_pos = pos - 1
                  [Map.put(current, :char_end, end_pos) | done]
                else
                  done
                end
              else
                done
              end

            # Update heading stack — drop same/deeper levels, append new heading
            new_stack =
              current.heading_stack
              |> Enum.reject(fn {l, _} -> l >= level end)
              |> Kernel.++([{level, text}])

            {done, %{heading_stack: new_stack, lines: [line], char_start: pos}, pos + line_len}

          nil ->
            {done, %{current | lines: [line | current.lines]}, pos + line_len}
        end
      end)

    # Flush final section
    final_sections =
      if last_section.lines != [] do
        section_text =
          last_section.lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()

        if section_text != "" do
          body_len = byte_size(body)
          [Map.put(last_section, :char_end, body_len) | sections]
        else
          sections
        end
      else
        sections
      end

    # Handle case where body has no headings at all
    result = Enum.reverse(final_sections)

    if result == [] do
      trimmed = String.trim(body)

      if trimmed != "" do
        [
          %{
            heading_stack: [],
            lines: [trimmed],
            char_start: 0,
            char_end: byte_size(body)
          }
        ]
      else
        []
      end
    else
      result
    end
  end

  # ---------------------------------------------------------------------------
  # Chunk building
  # ---------------------------------------------------------------------------

  defp build_chunks(sections, folder, title) do
    sections
    |> Enum.flat_map(fn section ->
      text = section.lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()
      heading_path = build_heading_path(title, section.heading_stack)
      context_prefix = build_context_prefix(folder, heading_path)

      sub_chunks =
        if byte_size(text) > @max_chunk_chars do
          split_text(text, @max_chunk_chars)
        else
          [text]
        end

      Enum.with_index(sub_chunks)
      |> Enum.map(fn {sub_text, sub_idx} ->
        %{
          text: sub_text,
          context_text: context_prefix <> "\n\n" <> sub_text,
          heading_path: heading_path,
          char_start: section.char_start,
          char_end: section.char_end,
          _sub_idx: sub_idx
        }
      end)
    end)
    |> Enum.with_index()
    |> Enum.map(fn {chunk, idx} ->
      chunk
      |> Map.delete(:_sub_idx)
      |> Map.put(:position, idx)
    end)
  end

  # No headings in document — use the document title
  defp build_heading_path(title, []), do: title

  # Stack starts with h1: replace h1 text with the extracted title (may differ if frontmatter
  # title overrides h1 text), append h2+ headings
  defp build_heading_path(title, [{1, _h1} | rest]) do
    subheadings = Enum.map(rest, fn {_level, text} -> text end)
    ([title] ++ subheadings) |> Enum.join(" > ")
  end

  # No h1 in stack (document starts at h2+) — prepend the document title
  defp build_heading_path(title, stack) do
    headings = Enum.map(stack, fn {_level, text} -> text end)
    ([title] ++ headings) |> Enum.join(" > ")
  end

  defp build_context_prefix(folder, heading_path) do
    if folder != "" do
      folder <> " > " <> heading_path
    else
      heading_path
    end
  end

  # ---------------------------------------------------------------------------
  # Sub-chunking (word boundary split)
  # ---------------------------------------------------------------------------

  defp split_text(text, max_chars) do
    words = String.split(text, " ")

    {chunks, current} =
      Enum.reduce(words, {[], ""}, fn word, {done, acc} ->
        candidate = if acc == "", do: word, else: acc <> " " <> word

        cond do
          byte_size(candidate) <= max_chars ->
            {done, candidate}

          # The word alone overflows, so flushing `acc` here would strand it as
          # a runt chunk — a bare "#" when a heading line is followed by a
          # space-free run — and the word would still need splitting after.
          # Cut the combined text instead, which fills the current chunk to the
          # brim and leaves the remainder as the next accumulator. A runt
          # embeds to a meaningless vector and still costs a Qdrant point.
          byte_size(word) > max_chars ->
            [tail | full] = candidate |> hard_split(max_chars) |> Enum.reverse()
            {full ++ done, tail}

          true ->
            {[acc | done], word}
        end
      end)

    all = if current != "", do: [current | chunks], else: chunks
    Enum.reverse(all)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp extract_folder(path) do
    case String.split(path, "/") do
      [_filename] -> ""
      parts -> parts |> Enum.drop(-1) |> Enum.join("/")
    end
  end
end
