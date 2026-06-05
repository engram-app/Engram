defmodule Engram.NotesScopeLintTest do
  @moduledoc """
  Grep-style lint: every `from(n in Note, ...)` in `lib/` must either
  be paired with a `kind == "note"` predicate or live in an
  explicitly-allowlisted file (kind-aware sites that intentionally
  scan all kinds: list_folders_with_counts, list_explicit_folders,
  do_rename_folder, find_folder_marker).
  """
  use ExUnit.Case, async: true

  @lib_dir Path.expand("../../lib/engram", __DIR__)

  # Files allowed to query notes without `kind == "note"`.
  #
  # Each entry must include a comment explaining WHY the file is kind-agnostic.
  # If you add a new Note query elsewhere, the lint will catch you — either
  # add the kind filter, or move your file here with a justification.
  @allowlist [
    # Folder-aware CRUD (list_folders_with_counts, list_explicit_folders,
    # do_rename_folder, find_folder_marker) intentionally scans all kinds.
    "notes.ex",
    # AAD rebind is an encryption-layer maintenance pass over every row that
    # holds encrypted fields — markers carry encrypted folder/path/title too
    # and must be rebound, so kind is irrelevant.
    "crypto/aad_rebind.ex",
    # Content-hash HMAC backfill is gated by `not is_nil(content_hash)`, which
    # already excludes markers (no content) implicitly; the worker treats the
    # row purely as a cryptographic blob.
    "workers/backfill_content_hash_hmac.ex",
    # `stamp_embed_hash` is a point-update by primary key on a Note already
    # selected upstream by the embed pipeline (which excludes markers via
    # notes_only/0); the query itself is kind-agnostic by design.
    "workers/embed_note.ex"
  ]

  test "every from(n in Note, ...) in lib/ filters by kind or is allowlisted" do
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

    Regex.scan(~r/from\(n in Note,.{1,500}/s, content)
    |> Enum.map(fn [block] -> {Path.relative_to(path, @lib_dir), block} end)
    |> Enum.reject(fn {_path, block} ->
      block =~ ~r/n\.kind\s*==\s*"note"/
    end)
  end

  defp format(offenders) do
    Enum.map_join(offenders, "\n\n", fn {file, block} ->
      "Unscoped Note query in #{file}:\n#{String.slice(block, 0, 200)}…"
    end)
  end
end
