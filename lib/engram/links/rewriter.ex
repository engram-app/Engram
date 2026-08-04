defmodule Engram.Links.Rewriter do
  @moduledoc """
  Server-side wikilink/embed rewriter for rename/move propagation
  (issues #648/#1231, Phase 1).

  When a note or attachment is renamed via REST or MCP, referring notes'
  `[[wikilink]]`/`![[embed]]` targets are rewritten to the new name. The
  server is the SINGLE rewriter for every origin EXCEPT plugin-origin
  renames (Obsidian's "Automatically update internal links" owns those) —
  exactly one party rewrites, never both.

  POLICY: the server authors only mechanical, semantics-preserving
  transforms — the rewritten target resolves to the same row the old text
  resolved to, and `!` embed markers, `|alias`, and `#anchor` segments are
  preserved verbatim. The server never authors content the user didn't
  write.

  Rewrites are authored as real Y-updates on the note's canonical doc
  (checkpoint snapshot + `crdt_update_log` tail — `bind/3`'s recipe) and
  appended/broadcast through the SAME persistence path client updates use
  (`CrdtPersistence.update_v1/4`, or the live room when one exists), so
  live editors converge and no content snapshot is ever written.

  Occurrence membership is decided by `Links.pre_rename_winner?/6`
  (pre-rename candidate reconstruction), NOT by current edge target ids —
  the `RebindNoteLinks` jobs the same rename enqueues race this worker and
  flip those ids.
  """

  alias Engram.Links
  alias Engram.Links.Parser

  @note_exts ~w(.md .canvas)

  @doc """
  Plan the target-segment edits for one source note.

  `full_text` is the note's full projected plaintext (what the parser
  runs on); `body` is the Y.Text body (`full_text` minus the frontmatter
  prefix — pass `full_text` itself for plaintext-only callers). Returned
  `rel_start`/`len` are byte offsets into `body`. Idempotent: occurrences
  already carrying the new text plan no edit.
  """
  @spec plan_edits(map(), map(), String.t(), String.t(), map()) :: [map()]
  def plan_edits(user, vault, full_text, body, target) do
    body_start = byte_size(full_text) - byte_size(body)
    old_key = Links.basename_key(target.old_path)

    full_text
    |> Parser.extract()
    |> Enum.filter(fn occ ->
      Links.basename_key(occ.target) == old_key and
        Links.pre_rename_winner?(user, vault, occ.target, target.kind, target.id, target.old_path)
    end)
    |> Enum.flat_map(fn occ ->
      replacement = replacement_target(occ.target, target)
      rel = occ.target_start - body_start

      cond do
        # Already the new text — idempotent no-op.
        occ.target == replacement -> []
        # Occurrence sits before the body (frontmatter) — the parser already
        # excludes frontmatter, so this is belt-and-suspenders only.
        rel < 0 -> []
        true -> [%{rel_start: rel, len: occ.target_len, old: occ.target, new: replacement}]
      end
    end)
  end

  @doc false
  @spec splice(String.t(), [map()]) :: String.t()
  def splice(text, edits) do
    edits
    |> Enum.sort_by(& &1.rel_start, :desc)
    |> Enum.reduce(text, fn e, acc ->
      binary_part(acc, 0, e.rel_start) <>
        e.new <>
        binary_part(acc, e.rel_start + e.len, byte_size(acc) - e.rel_start - e.len)
    end)
  end

  # Form rule: bare stays bare when the new basename is unambiguous
  # (target.collision? == false); path-qualified when the occurrence was
  # already path-qualified OR the new basename collides. Casing comes from
  # the actual stored new path. The occurrence's extension form is
  # preserved: `[[Old.md]]` -> `[[Fresh.md]]`, `[[Old]]` -> `[[Fresh]]`;
  # non-note extensions (attachments) always keep theirs.
  defp replacement_target(occ_target, %{new_path: new_path, collision?: collision?}) do
    qualified? = String.contains?(occ_target, "/") or collision?
    occ_ext = occ_target |> Path.basename() |> Path.extname() |> String.downcase()
    keep_note_ext? = occ_ext in @note_exts

    base = if qualified?, do: new_path, else: Path.basename(new_path)
    new_ext = Path.extname(base)

    if String.downcase(new_ext) in @note_exts and not keep_note_ext? do
      String.replace_suffix(base, new_ext, "")
    else
      base
    end
  end
end
