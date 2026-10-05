defmodule Engram.Parsers.Markdown do
  @moduledoc """
  Heading-aware markdown chunker.

  Splits content at heading boundaries, builds folder-aware context prefixes,
  and splits large sections at content-defined paragraph, line, sentence or
  word boundaries (~512 tokens / 2048 bytes).
  The chunking runs in Rust: native/engram_native/src/chunker.rs.
  """

  alias Engram.Notes.Helpers

  # #1620 — bump when a change alters the chunks `parse/2` emits for input it
  # already handled: a different split point, different chunk text, different
  # ordering. Do NOT bump for a change that cannot move a boundary (a typespec,
  # a comment, a refactor with identical output). Every bump costs one re-embed
  # pass over the corpus.
  #
  # 2 — base64 blobs are stripped from section text (`strip_blobs/1`).
  # 3 — CommonMark headings (none inside code; setext counts), only the first
  #     H1 is the title, heading-only and blank chunks dropped, whitespace
  #     normalised, content-anchored splits (#1594), `embed_text` (#1621).
  @chunker_version 3

  @doc """
  Version of the chunking algorithm in this build (#1620).

  Stamped onto `notes.chunker_version` by `EmbedNote` after a successful index
  and compared there on the next pass: a note carrying anything else — including
  NULL, meaning it was indexed before this stamp existed — is rebuilt rather
  than skipped, which is how a chunker fix reaches notes nobody edits.
  """
  # No @spec: the body is a literal, so dialyzer narrows the success typing to
  # that exact integer and rejects any wider contract as a supertype.
  def chunker_version, do: @chunker_version

  @doc """
  Parse markdown content into indexable chunks.

  Returns a list of chunk maps:
  - `:position`     — sequential index (0-based)
  - `:text`         — raw chunk text (no context prefix)
  - `:context_text` — "folder > title > heading\\n\\ntext" for keyword search
  - `:embed_text`   — "title > heading\\n\\ntext" for dense embedding: no
                      folder, so moving a note keeps its vectors (#1621)
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
    # Invalid UTF-8 is scrubbed: the Rust side takes only valid text.
    content = content |> Helpers.scrub_utf8() |> String.replace("\r\n", "\n")
    folder = extract_folder(path)
    title = Helpers.extract_title(content, path)

    content
    |> Engram.Native.chunk(folder, title)
    |> Enum.with_index(fn {text, context_text, embed_text, heading_path, char_start, char_end},
                          position ->
      %{
        position: position,
        text: text,
        context_text: context_text,
        embed_text: embed_text,
        heading_path: heading_path,
        char_start: char_start,
        char_end: char_end
      }
    end)
  end

  defp extract_folder(path) do
    case String.split(path, "/") do
      [_filename] -> ""
      parts -> parts |> Enum.drop(-1) |> Enum.join("/")
    end
  end
end
