defmodule Engram.Parsers.Markdown do
  @moduledoc """
  Heading-aware markdown chunker.

  Splits content at heading boundaries, builds folder-aware context prefixes,
  and splits large sections at content-defined paragraph, line, sentence or
  word boundaries (~512 tokens / 2048 bytes).
  The chunking runs in Rust: native/engram_native/src/chunker.rs.
  """

  alias Engram.Notes.Frontmatter
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
  # 4: wrapped base64 and hex blobs stripped, and a per-chunk `kind`: a
  #     frontmatter chunk is keyword-only, so it no longer holds a dense vector.
  #     NOT stamped yet: held at 3 so prod rebuilds once, when the bundled
  #     re-chunk lands (embed-less, merge cap, storage move). Until then the
  #     v4 chunker applies to new and edited notes only.
  # Unstamped, rides the next bump (the bundled v5 rebuild): a run with no
  # space is cut between words, never inside one (`word_split` in Rust).
  @chunker_version 3

  @data_exts [".canvas", ".base"]

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

  @doc "Most bytes of `text` one chunk holds (`MAX_CHUNK` in chunker.rs)."
  def max_chunk, do: 2_048

  @doc """
  Parse markdown content into indexable chunks.

  Returns a list of chunk maps:
  - `:position`     — sequential index (0-based)
  - `:text`         — raw chunk text (no context prefix)
  - `:context_text` — "folder > title > heading\\n\\ntext" for keyword search
  - `:embed_text`   — "title > heading\\n\\ntext" for dense embedding: no
                      folder, which is a filter key, not meaning (#1621)
  - `:heading_path` — e.g. "Title > H1 > H2" (`:headings` joined)
  - `:headings`     — the same path as a list, title first: a heading
                      may itself contain " > " (chunker v5). A merged
                      chunk's path is the one all its sections share.
  - `:section_count` — how many sections the chunk joins (min512); 1 when
                      it is one section, or part of one
  - `:char_start`   — byte offset in post-frontmatter body
  - `:char_end`     — byte offset end
  - `:kind`:         "prose" | "data" | "frontmatter" | "drawing" |
                      "frontmatter_dense" | "canvas_dense"; only the
                      `dense_kind?/1` ones get a dense vector, the rest are
                      keyword-only

  A `.canvas` or `.base` note has no `"prose"` chunks: they are all `"data"`,
  except that a canvas's text cards (at most 2 KB) are the dense input of its
  first chunk, `"canvas_dense"`. A note of properties alone has one
  `"frontmatter_dense"` chunk: its dense input is the title and the values.
  An Excalidraw note (frontmatter `excalidraw-plugin`) loses its drawing JSON.

  Exception: when frontmatter is present, a synthetic chunk carrying the raw
  frontmatter block is appended last, with `heading_path` fixed to
  `"frontmatter"`, `kind` `"frontmatter"` and `char_start`/`char_end` both
  fixed to `0`.
  """
  def parse("", _path), do: []

  def parse(content, path) do
    # The frontmatter codec and the heading patterns all expect LF, so a CRLF
    # note lost its frontmatter chunk and had its body cut short (#1605).
    # Invalid UTF-8 is scrubbed: the Rust side takes only valid text.
    # A leading BOM is dropped here only, so a BOM note's frontmatter
    # chunks as frontmatter; the shared splitter (CRDT ingest) keeps it.
    content =
      content
      |> Helpers.scrub_utf8()
      |> String.replace("\r\n", "\n")
      |> String.replace_prefix("\uFEFF", "")

    folder = extract_folder(path)
    title = Helpers.extract_title(content, path)
    # Structured files (JSON canvas, Obsidian bases) are keyword-only whole.
    data? = Path.extname(path) in @data_exts

    fm = frontmatter(content)

    content
    |> Engram.Native.chunk(folder, title, aliases(fm, title), lead(fm))
    |> canvas_cards(path, content)
    |> Enum.with_index(fn {text, context_text, embed_text, {headings, members}, char_start,
                           char_end, kind},
                          position ->
      %{
        position: position,
        text: text,
        context_text: context_text,
        embed_text: embed_text,
        heading_path: Enum.join(headings, " > "),
        headings: headings,
        section_count: members,
        char_start: char_start,
        char_end: char_end,
        kind: if(data? and kind == "prose", do: "data", else: kind)
      }
    end)
  end

  @doc "Whether chunks of `kind` get a dense vector."
  @spec dense_kind?(String.t()) :: boolean()
  def dense_kind?(kind), do: kind in ~w(prose frontmatter_dense canvas_dense)

  @max_cards 2_048
  # ponytail: a canvas over this keeps its cards keyword-only rather than
  # decode the whole JSON on the embed worker (review L5).
  @max_canvas_decode 1_048_576

  # F12: the cards are a canvas's prose. The point count does not change:
  # the first chunk carries them as its dense input.
  defp canvas_cards([{text, ctx, embed, hs, s, e, _kind} | rest] = chunks, path, content) do
    with ".canvas" <- Path.extname(path),
         true <- byte_size(content) <= @max_canvas_decode,
         {:ok, %{"nodes" => nodes}} when is_list(nodes) <- Jason.decode(content),
         cards when cards != "" <- card_text(nodes) do
      prefix = binary_part(embed, 0, byte_size(embed) - byte_size(text) - 2)
      [{text, ctx, prefix <> "\n\n" <> cards, hs, s, e, "canvas_dense"} | rest]
    else
      _ -> chunks
    end
  end

  defp canvas_cards([], _path, _content), do: []

  defp card_text(nodes) do
    nodes
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => t} when is_binary(t) -> [t |> strip_blobs() |> String.trim()]
      _ -> []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> cut_bytes(@max_cards)
  end

  # A pasted image or attachment in a card is base64, not meaning (review
  # L6): a run of 100+ base64 chars with both cases and digits goes, as the
  # chunker's `strip_blobs` does for note text.
  defp strip_blobs(t) do
    Regex.replace(~r/(?:data:[\w\/+.-]+;base64,)?[A-Za-z0-9+\/=_-]{100,}/, t, fn run ->
      if run =~ ~r/[A-Z]/ and run =~ ~r/[a-z]/ and run =~ ~r/[0-9]/, do: "", else: run
    end)
  end

  # The longest valid UTF-8 prefix of at most `max` bytes.
  defp cut_bytes(s, max) when byte_size(s) <= max, do: s
  defp cut_bytes(s, max), do: s |> binary_part(0, max) |> String.chunk(:valid) |> hd()

  # The decoded top-level frontmatter values; %{} when there is none or it
  # is not YAML.
  # Only the keys the prefix and lead read; a block naming none of them is
  # not parsed at all (review L5: YamlElixir on every embed pass).
  defp frontmatter(content) do
    with {block, _body} when is_binary(block) <- Frontmatter.split(content),
         true <- String.contains?(block, ["alias", "description"]),
         {:ok, _order, values, _degraded} <- Frontmatter.parse(block) do
      Map.new(values, fn {k, v} -> {k, Jason.decode!(v)} end)
    else
      _ -> %{}
    end
  end

  @doc """
  The note's aliases for the chunk prefix: `aliases` (a list or one
  scalar) then the legacy `alias`, strings and numbers only, trimmed, empty
  ones dropped, deduplicated case-insensitively against each other and the
  title. The chunker joins them and caps the part at 200 chars.
  """
  @spec aliases(map(), String.t()) :: [String.t()]
  def aliases(values, title) do
    ["aliases", "alias"]
    |> Enum.flat_map(&List.wrap(values[&1]))
    |> Enum.flat_map(fn
      v when is_binary(v) -> [one_line(v)]
      v when is_number(v) -> [to_string(v)]
      _ -> []
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
    |> Enum.reject(&(String.downcase(&1) == String.downcase(title)))
  end

  @max_lead 200
  # A type is a word or two; a pasted one must not grow a paid input (M6).
  @max_type 64

  @doc """
  The line after the first chunk's prefix: `"Type: description"`, or the
  description alone; nil without a description (a `type` alone adds
  nothing). The description is one line, cut at 200 B. Note content: never
  log it.
  """
  @spec lead(map()) :: String.t() | nil
  def lead(values) do
    with d when is_binary(d) <- values["description"],
         d when d != "" <- d |> one_line() |> cut_bytes(@max_lead) do
      case values["type"] do
        t when is_binary(t) and t != "" -> cut_bytes(one_line(t), @max_type) <> ": " <> d
        _ -> d
      end
    else
      _ -> nil
    end
  end

  defp one_line(s), do: s |> String.split() |> Enum.join(" ")

  defp extract_folder(path) do
    case String.split(path, "/") do
      [_filename] -> ""
      parts -> parts |> Enum.drop(-1) |> Enum.join("/")
    end
  end
end
