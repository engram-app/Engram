defmodule Engram.Links.Parser do
  @moduledoc """
  Pure extraction of Obsidian-style links from plaintext markdown — both
  syntaxes: `[[wikilink]]`/`![[embed]]` and the markdown form
  `[label](target.md)`/`![alt](img.png)` that Obsidian writes when
  **Settings -> Files & Links -> "Use [[Wikilinks]]"** is off (#1302).

  Positions are byte offsets into the ORIGINAL content (stable for snippet
  reconstruction), which is why exclusion works by range-filtering rather than
  stripping (stripping would shift every downstream offset). For invalid-UTF-8
  input, positions are byte offsets into the scrubbed content (what any reader
  renders).

  Each occurrence carries two views of its target, which differ only for
  markdown links:

    * `target` — the DECODED vault path (`My%20Note.md` -> `My Note.md`).
      This is what `Links.basename_key/1` and `Links.resolve_target/4`
      consume, so resolution behaves identically for both syntaxes.
    * `target_raw` — the literal bytes at `target_start`/`target_len`, so
      `binary_part(content, target_start, target_len) == target_raw` always
      holds and `Links.Rewriter` can splice without re-deriving the span.

  `link_type` stays `"wikilink"`/`"embed"` — it answers "is this an embed",
  not "how was it written" — and the syntax lives in `form`
  (`:wiki | :markdown`). Keeping them separate means `resolve_target/4`,
  the `note_links.link_type` column and every existing consumer are
  untouched by markdown support.
  """

  alias Engram.Notes.Helpers

  # Matching, code/frontmatter exclusion and per-link cleaning (trim, `#`
  # and `|` splits, `<...>` destinations, percent-decoding, the external-URL
  # check) all run in Rust: `Engram.Native.link_extract/2`, see
  # native/engram_native/src/links.rs. It returns links in position order,
  # one per position: `note_links` is unique on (source_note_id, position).

  # The edges stored per note. One link costs ~250 B as BEAM terms and a
  # row: 10 MB of `[[a]]` is 1.75M links and 713 MB. Real notes have
  # hundreds. Past @max_links by position, only the first occurrence of
  # each target not yet stored is kept (up to @max_links more), so every
  # target keeps an edge: the rename rewrite finds its source notes through
  # stored edges, and a link it cannot find stays dangling. Overflow is
  # counted (`[:engram, :links, :truncated]`), never an error: the note
  # still saves, indexes and searches in full.
  @max_links 20_000

  @doc "Links of `content`: the first #{@max_links}, then one per new target."
  @spec extract(String.t()) :: [map()]
  def extract(content) when is_binary(content) do
    {links, cut?} = extract(content, @max_links)
    if cut?, do: :telemetry.execute([:engram, :links, :truncated], %{count: 1}, %{})
    links
  end

  @doc """
  Every link of `content`, uncapped. For the rename rewrite, which must
  change each occurrence or leave it dangling; it does not store them.
  """
  @spec extract_all(String.t()) :: [map()]
  def extract_all(content) when is_binary(content),
    do: content |> extract(:infinity) |> elem(0)

  defp extract(content, limit) do
    content = if String.valid?(content), do: content, else: Helpers.scrub_utf8(content, :write)
    # usize::MAX for the NIF's "no limit".
    limit = if limit == :infinity, do: 0xFFFF_FFFF_FFFF_FFFF, else: limit
    {links, scrubs, cut?} = Engram.Native.link_extract(content, limit)

    # A percent escape can decode to invalid UTF-8 (`%FF`). Unscrubbed, that
    # target is encrypted, stored, then decrypted straight into a JSON
    # response, where Jason.encode! raises on every read of the note's
    # backlinks. Rust scrubs it; report each the way scrub_utf8/2 would.
    for _ <- 1..scrubs//1, do: Helpers.report_scrub(:write)

    {Enum.map(links, fn {position, kind, target_start, target_len, target, alias_, anchor} ->
       %{
         target: target,
         target_raw: binary_part(content, target_start, target_len),
         target_start: target_start,
         target_len: target_len,
         alias: alias_,
         anchor: anchor,
         # kind: 0 wiki, 1 wiki embed, 2 markdown, 3 markdown embed.
         link_type: if(kind in [0, 2], do: "wikilink", else: "embed"),
         form: if(kind < 2, do: :wiki, else: :markdown),
         position: position
       }
     end), cut?}
  end
end
