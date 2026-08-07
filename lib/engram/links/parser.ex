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

  # `!` optional (embed), lazy target up to `]]`; `u` flag is load-bearing (#741).
  @link_re ~r/(!?)\[\[([^\]\[]+?)\]\]/u

  # Markdown link/embed.
  #
  # The label class excludes `[` as well as `]` — matching @link_re's shape,
  # and NOT optional. With a bare `[^\]]*` a long run of unmatched `[` has no
  # early exit, so Regex.scan re-scans from every one of them: measured 14.2s
  # on a 100KB bracket run, against 37ms for @link_re on the same input.
  # Excluding `[` also means a nested `[[wikilink]]` inside a label cannot
  # match here, so it is left to @link_re — no double extraction.
  #
  # The destination admits one level of balanced parens so a real path like
  # `My (file).md` is captured whole. A bare `[^)]*` truncated it to
  # `My (file` and wrote THAT as a note_links target — a garbage edge, not a
  # skip. The two alternation branches are disjoint on their first character
  # (`[^()]` vs `\(`), so there is no ambiguity to backtrack through.
  # ponytail: one level only. Deeper nesting needs a real balanced scan;
  # CommonMark itself only guarantees balance, not depth.
  @md_link_re ~r/(!?)\[([^\]\[]*)\]\(((?:[^()]|\([^()]*\))*)\)/u

  # Anything with a scheme (`https:`, `mailto:`), protocol-relative (`//cdn`),
  # or a bare same-page anchor is not a vault link.
  @external_re ~r/\A(?:[a-z][a-z0-9+.\-]*:|\/\/)/i

  # Whitespace that ends an unbracketed markdown destination.
  @ws [" ", "\t", "\n", "\r"]

  # Ranges to exclude: fenced code, inline code. Frontmatter handled separately.
  @exclusion_res [~r/```.*?```/su, ~r/~~~.*?~~~/su, ~r/`[^`\n]*`/u]
  @frontmatter_re ~r/\A---\s*\n.*?\n---\s*\n/su

  @spec extract(String.t()) :: [map()]
  def extract(content) when is_binary(content) do
    do_extract(if String.valid?(content), do: content, else: Helpers.scrub_utf8(content, :write))
  end

  defp do_extract(content) do
    excluded = exclusion_ranges(content)

    (extract_wiki(content) ++ extract_markdown(content))
    |> Enum.reject(fn %{position: pos} -> in_ranges?(pos, excluded) end)
    |> Enum.sort_by(& &1.position)
    # `note_links` has unique_index([:source_note_id, :position]), so two
    # occurrences reporting the same start byte would fail the insert with a
    # 500 on ordinary user text. I could not construct a case where the two
    # regexes both match at one offset (a wikilink needs `]]`, which stops
    # the markdown label), so this is identity today — but it is one pass
    # over a short list to make that reasoning non-load-bearing.
    |> Enum.uniq_by(& &1.position)
  end

  defp extract_wiki(content) do
    @link_re
    |> Regex.scan(content, return: :index)
    |> Enum.flat_map(fn [{start, _len}, {_, bang_len}, {inner_start, inner_len}] ->
      inner = binary_part(content, inner_start, inner_len)

      case parse_inner(inner) do
        nil ->
          []

        parsed ->
          [
            parsed
            |> Map.update!(:target_start, &(&1 + inner_start))
            |> Map.merge(%{
              link_type: link_type(bang_len),
              form: :wiki,
              target_raw: parsed.target,
              position: start
            })
          ]
      end
    end)
  end

  defp extract_markdown(content) do
    @md_link_re
    |> Regex.scan(content, return: :index)
    |> Enum.flat_map(fn [
                          {start, _len},
                          {_, bang_len},
                          {label_start, label_len},
                          {dest_start, dest_len}
                        ] ->
      case md_target_span(content, dest_start, dest_len) do
        nil ->
          []

        {target_start, target_len, anchor} ->
          raw = binary_part(content, target_start, target_len)

          [
            %{
              target: percent_decode(raw),
              target_raw: raw,
              target_start: target_start,
              target_len: target_len,
              alias: clean(binary_part(content, label_start, label_len)),
              anchor: anchor,
              link_type: link_type(bang_len),
              form: :markdown,
              position: start
            }
          ]
      end
    end)
  end

  # Narrows the raw `(...)` destination down to just the target's byte span,
  # then peels a `#anchor` tail. Returns nil for anything that isn't a vault
  # path. Every step adjusts start/len rather than rebuilding a string, so
  # the returned span still indexes into the ORIGINAL content.
  defp md_target_span(content, dest_start, dest_len) do
    {s, l} = trim_span(content, dest_start, dest_len)
    {s, l} = destination_span(content, s, l)
    {s, l, anchor} = split_anchor(content, s, l)

    if l == 0 or Regex.match?(@external_re, binary_part(content, s, l)),
      do: nil,
      else: {s, l, anchor}
  end

  # CommonMark: a destination is either `<...>` (may contain spaces) or a run
  # of NON-WHITESPACE characters, and whatever follows is the title. So the
  # destination ends at the first whitespace — one `:binary.match`, linear.
  #
  # This replaced a `~r/\s+(?:"[^"]*"|'[^']*')\s*\z/u` title-stripper, which
  # backtracked quadratically: an unanchored `\s+` retried from every offset
  # in a whitespace run, measured 67s on 100KB of spaces. This parser runs
  # synchronously on every note write, so that was reachable by accident (a
  # pasted or corrupted destination), not just by malice. Taking the
  # first-whitespace rule is simultaneously spec-correct AND linear.
  defp destination_span(content, s, l) do
    if l >= 1 and binary_part(content, s, 1) == "<" do
      case :binary.match(binary_part(content, s + 1, l - 1), ">") do
        {idx, _} -> {s + 1, idx}
        # Unterminated `<` — not a bracketed destination, take it literally.
        :nomatch -> {s, l}
      end
    else
      case :binary.match(binary_part(content, s, l), @ws) do
        {idx, _} -> {s, idx}
        :nomatch -> {s, l}
      end
    end
  end

  defp split_anchor(content, s, l) do
    part = binary_part(content, s, l)

    case :binary.match(part, "#") do
      {idx, _} -> {s, idx, clean(URI.decode(binary_part(part, idx + 1, l - idx - 1)))}
      :nomatch -> {s, l, nil}
    end
  end

  defp trim_span(content, start, len) do
    slice = binary_part(content, start, len)
    lead = byte_size(slice) - byte_size(String.trim_leading(slice))
    {start + lead, byte_size(String.trim(slice))}
  end

  # `URI.decode/1` never raises — its unpercent/3 re-emits a literal `%` for
  # any malformed escape — so `%ZZ` survives as author text with no rescue
  # needed. It CAN produce invalid UTF-8 though (`%FF`), and that must not
  # escape this module: an unscrubbed target is encrypted, stored, then
  # decrypted straight into a JSON response, where Jason.encode! raises and
  # 500s every read of that note's backlinks — permanently, from one typed
  # character. Scrub here, the same gate `clean/1` applies to alias/anchor.
  defp percent_decode(s), do: s |> URI.decode() |> Helpers.scrub_utf8(:write)

  defp link_type(0), do: "wikilink"
  defp link_type(_), do: "embed"

  # `target_start`/`target_len` are the byte span of the TRIMMED target
  # within `inner` (do_extract/1 shifts by the match offset): the |-then-#
  # split already isolates the raw target, so the offsets fall out here
  # instead of being re-derived elsewhere. do_extract/1 runs on
  # already-scrubbed content, so clean/1's scrub is an identity there and
  # `binary_part(content, target_start, target_len) == target` holds.
  defp parse_inner(inner) do
    {body, alias_} =
      case String.split(inner, "|", parts: 2) do
        [body] -> {body, nil}
        [body, a] -> {body, clean(a)}
      end

    {target_raw, anchor} =
      case String.split(body, "#", parts: 2) do
        [t] -> {t, nil}
        [t, an] -> {t, clean(an)}
      end

    case clean(target_raw) do
      nil ->
        nil

      target ->
        lead = byte_size(target_raw) - byte_size(String.trim_leading(target_raw))

        %{
          target: target,
          alias: alias_,
          anchor: anchor,
          target_start: lead,
          target_len: byte_size(String.trim(target_raw))
        }
    end
  end

  defp clean(s) do
    case s |> String.trim() |> Helpers.scrub_utf8(:write) do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp exclusion_ranges(content) do
    fm =
      case Regex.run(@frontmatter_re, content, return: :index) do
        [{0, len} | _] -> [{0, len}]
        _ -> []
      end

    code =
      Enum.flat_map(@exclusion_res, fn re ->
        re |> Regex.scan(content, return: :index) |> Enum.map(fn [{s, l} | _] -> {s, l} end)
      end)

    fm ++ code
  end

  defp in_ranges?(pos, ranges),
    do: Enum.any?(ranges, fn {s, l} -> pos >= s and pos < s + l end)
end
