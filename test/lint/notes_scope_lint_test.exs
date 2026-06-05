defmodule Engram.NotesScopeLintTest do
  @moduledoc """
  Grep-style lint: every `from(<binding> in Note, ...)` (or the fully-qualified
  `Engram.Notes.Note` form) anywhere under `lib/` must either be paired with a
  `<binding>.kind == "note"` predicate or live in an explicitly-allowlisted
  file. The walker scans all of `lib/` (not just `lib/engram/`) so that
  controllers, channels, mix tasks, and any other layer are covered.
  """
  use ExUnit.Case, async: true

  @lib_dir Path.expand("../../lib", __DIR__)

  # Files allowed to query notes without `kind == "note"`.
  #
  # Each entry must include a comment explaining WHY the file is kind-agnostic.
  # If you add a new Note query elsewhere, the lint will catch you — either
  # add the kind filter, or move your file here with a justification.
  @allowlist [
    # Folder-aware CRUD (list_folders_with_counts, list_explicit_folders,
    # do_rename_folder, find_folder_marker) intentionally scans all kinds.
    "engram/notes.ex",
    # AAD rebind operates only on legacy rows (`dek_version == legacy_version`).
    # Folder markers are created at the current dek_version, so they cannot
    # match the predicate and are excluded structurally — no kind filter needed.
    "engram/crypto/aad_rebind.ex",
    # Per-user DEK rotation (T3.7) MUST re-wrap every encrypted column on every
    # row that belongs to the user — including folder markers' `folder_*`
    # ciphertext. Restricting to `kind == "note"` would skip markers and leave
    # them wrapped under the old DEK, breaking rotation correctness.
    "engram/crypto/user_dek_rotation.ex",
    # Content-hash HMAC backfill is gated by `not is_nil(content_hash)`, which
    # already excludes markers (no content) implicitly; the worker treats the
    # row purely as a cryptographic blob.
    "engram/workers/backfill_content_hash_hmac.ex",
    # `stamp_embed_hash` is a point-update by primary key on a Note already
    # selected upstream by the embed pipeline (which excludes markers via
    # notes_only/0); the query itself is kind-agnostic by design.
    "engram/workers/embed_note.ex"
  ]

  test "every from(_ in Note, ...) in lib/ filters by kind or is allowlisted" do
    offenders =
      walk(@lib_dir)
      |> Enum.flat_map(&scan_file/1)
      |> Enum.reject(fn {file, _block} ->
        Enum.any?(@allowlist, &String.ends_with?(file, &1))
      end)

    assert offenders == [], format(offenders)
  end

  defp walk(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)

      cond do
        File.dir?(full) -> walk(full)
        String.ends_with?(entry, ".ex") -> [full]
        true -> []
      end
    end)
  end

  defp scan_file(path) do
    content = File.read!(path)

    # Match both `from(n in Note, ...)` and `from(n in Engram.Notes.Note, ...)`.
    # Capture the binding name so we can require `<binding>.kind == "note"`
    # inside the same `from(...)` block (not some unrelated nearby code).
    Regex.scan(~r/from\((\w+)\s+in\s+(?:Engram\.Notes\.)?Note,.{1,500}/s, content)
    |> Enum.map(fn [block, binding] ->
      {Path.relative_to(path, @lib_dir), block, binding}
    end)
    |> Enum.reject(fn {_path, block, binding} ->
      Regex.match?(~r/#{Regex.escape(binding)}\.kind\s*==\s*"note"/, block)
    end)
    |> Enum.map(fn {path, block, _binding} -> {path, block} end)
  end

  defp format(offenders) do
    Enum.map_join(offenders, "\n\n", fn {file, block} ->
      "Unscoped Note query in #{file}:\n#{String.slice(block, 0, 200)}…"
    end)
  end
end
