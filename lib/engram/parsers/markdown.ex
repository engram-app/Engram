defmodule Engram.Parsers.Markdown do
  @moduledoc """
  Heading-aware markdown chunker.

  Splits content at heading boundaries, builds folder-aware context prefixes,
  and sub-chunks large sections at word boundaries (~512 tokens / 2048 chars).
  """

  alias Engram.Notes.Helpers

  # ~4 chars per token; 512 tokens ≈ 2048 chars
  @max_chunk_chars 2048

  @doc """
  Parse markdown content into indexable chunks.

  Returns a list of chunk maps:
  - `:position`     — sequential index (0-based)
  - `:text`         — raw chunk text (no context prefix)
  - `:context_text` — "folder > title > heading\\n\\ntext" for embedding
  - `:heading_path` — e.g. "Title > H1 > H2"
  - `:char_start`   — byte offset in post-frontmatter body
  - `:char_end`     — byte offset end
  """
  def parse("", _path), do: []

  def parse(content, path) do
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

    body_chunks ++ frontmatter_chunk(content, folder, title, length(body_chunks))
  end

  # Frontmatter values used to be stripped before indexing, making every key
  # invisible to keyword search (spec 2026-07-02). One synthetic chunk carries
  # the raw block into the BM25 leg. char offsets are 0/0: the block sits
  # before the post-frontmatter body that offsets are relative to.
  defp frontmatter_chunk(content, folder, title, position) do
    case Engram.Notes.Frontmatter.split(content) do
      {block, _body} when is_binary(block) and block != "" ->
        context_prefix = build_context_prefix(folder, "#{title} > frontmatter")

        [
          %{
            text: block,
            context_text: context_prefix <> "\n\n" <> block,
            heading_path: "frontmatter",
            char_start: 0,
            char_end: 0,
            position: position
          }
        ]

      _ ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Frontmatter
  # ---------------------------------------------------------------------------

  defp strip_frontmatter(content) do
    case Regex.run(~r/\A---\s*\n.*?\n---\s*\n/s, content, return: :index) do
      [{0, len}] -> String.slice(content, len, byte_size(content))
      _ -> content
    end
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

        if byte_size(candidate) > max_chars and acc != "" do
          {[acc | done], word}
        else
          {done, candidate}
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
