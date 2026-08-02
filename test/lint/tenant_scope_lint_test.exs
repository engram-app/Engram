defmodule Engram.TenantScopeLintTest do
  @moduledoc """
  Grep-style lint: the tenant-isolation predicate must not be hand-inlined.

  In an encrypted multi-tenant product, `user_id == ^user.id and
  vault_id == ^vault.id [and is_nil(deleted_at)]` IS the isolation boundary.
  It used to be inlined ~45 times across the three tenant contexts, and
  nothing caught a dropped clause. Queries must now compose from the
  per-context scope helpers:

    * `Engram.Notes.scoped/2` / `scoped_live/2`
    * `Engram.Vaults.scoped/1` (+ `active/1` / `deleted/1`)
    * `Engram.Attachments.scoped/2` / `scoped_live/2`

  This test flags any raw `<binding>.user_id == ^...` predicate in the three
  context files whose enclosing function is neither a scope helper nor an
  allowlisted, legitimately-divergent site. If it fires on your new query:
  compose from the helper. Only allowlist (with a WHY comment) when the
  helper genuinely cannot express the site's semantics.
  """
  use ExUnit.Case, async: true

  alias Engram.Test.SourceLint

  @lib_dir Path.expand("../../lib", __DIR__)

  @files ~w(engram/notes.ex engram/vaults.ex engram/attachments.ex)

  # A raw tenant predicate: `<binding>.user_id == ^...`. The leading `.`
  # keeps doc-prose mentions of "user_id == ^user_id" from tripping the lint.
  @raw_predicate ~r/\.\s*user_id\s*==\s*\^/

  # The scope helpers themselves — the one place the raw predicate lives.
  @helper_head ~r/^defp?\s+scoped/

  # Legitimately-divergent sites, keyed by {file, function-head prefix}.
  # Each entry needs a WHY: the helper cannot express the site's semantics.
  @allowlist [
    # Cross-vault by design: when `vault` is nil the path→id lookup scans all
    # of the user's vaults (search resolves Qdrant paths without a vault);
    # the vault clause is added conditionally, so scoped/2 doesn't fit.
    {"engram/notes.ex", "defp do_note_ids_for_paths("},
    # Bulk per-vault content counts: `vault_id in ^ids` (a GROUP BY across
    # many vaults in one query, skip_tenant_check for performance) — the
    # single-vault `vault_id == ^` shape of Notes/Attachments.scoped/2
    # cannot express the IN-list.
    {"engram/vaults.ex", "defp do_content_counts("},
    # Account-wide storage usage across ALL vaults (billing cap check) —
    # intentionally vault-agnostic, so the vault_id clause is absent.
    {"engram/attachments.ex", "def storage_usage(user) do"}
  ]

  test "tenant-isolation predicates compose from scoped/* helpers" do
    offenders =
      @files
      |> Enum.flat_map(&scan_file/1)
      |> Enum.reject(fn {file, _line_no, head, _line} ->
        Regex.match?(@helper_head, head) or
          Enum.any?(@allowlist, fn {f, prefix} ->
            f == file and String.starts_with?(head, prefix)
          end)
      end)

    assert offenders == [],
           "Hand-inlined tenant predicate found. This predicate is the " <>
             "multi-tenant isolation boundary — compose from Notes.scoped/2, " <>
             "Vaults.scoped/1, or Attachments.scoped/2 (see their @doc) instead " <>
             "of inlining `user_id == ^`. If the helper truly cannot express " <>
             "the site, allowlist it in #{Path.relative_to_cwd(__ENV__.file)} " <>
             "with a WHY comment.\n\n" <>
             Enum.map_join(offenders, "\n", fn {file, line_no, head, line} ->
               "#{file}:#{line_no} (in `#{head}`): #{String.trim(line)}"
             end)
  end

  # Walks the file line by line, tracking the enclosing `def`/`defp` head so
  # each raw-predicate hit can be attributed to (and allowlisted by) its
  # function. Comment lines are skipped via SourceLint.commented?/1.
  defp scan_file(rel) do
    @lib_dir
    |> Path.join(rel)
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce({"(module body)", []}, fn {line, line_no}, {head, acc} ->
      cond do
        Regex.match?(~r/^\s*defp?\s+\w/, line) ->
          {String.trim(line), acc}

        Regex.match?(@raw_predicate, line) and not SourceLint.commented?(line) ->
          {head, [{rel, line_no, head, line} | acc]}

        true ->
          {head, acc}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end
end
