defmodule Engram.Workers.NoPlaintextArgsTest do
  # T3.2 / H3 — Static source lint. Oban worker `args` is a JSONB column
  # in `oban_jobs.args` and lands in DB dumps, Oban Web UI, and retention
  # windows. Plaintext path / title / content / tags / folder / old_path /
  # name keys defeat Phase B's at-rest encryption for the duration of any
  # in-flight or recently-completed job.
  #
  # The audit's T3.2.3 acceptance criterion: "no `oban_jobs.args` row in
  # any worker enqueues keys named path|title|content|tags|folder|old_path|name."
  use ExUnit.Case, async: true

  alias Engram.Test.SourceLint

  @workers_dir Path.join(File.cwd!(), "lib/engram/workers")

  # Banned keys when used as map literal keys in worker args. Match shape:
  #   "path" =>          # JSON-string-keyed args
  #   path:              # atom-keyed args
  # Per audit T3.2.3.
  @banned_keys ~w(path title content tags folder old_path name)

  test "no Oban worker file uses banned plaintext arg keys" do
    offenders =
      @workers_dir
      |> SourceLint.walk_ex_files()
      |> Enum.flat_map(&scan_file/1)

    assert offenders == [],
           "Oban worker source contains banned plaintext arg keys.\n" <>
             "Replace `path` / `old_path` with `path_hmac` / `old_path_hmac` (base64).\n" <>
             "Other plaintext fields (title/content/tags/folder/name) must never enter\n" <>
             "oban_jobs.args — they are JSONB and survive in DB dumps + retention.\n\n" <>
             Enum.map_join(offenders, "\n", fn {file, line, key, snippet} ->
               "  #{Path.relative_to_cwd(file)}:#{line}  [#{key}]  #{snippet}"
             end)
  end

  defp scan_file(path) do
    lines = path |> File.read!() |> String.split("\n") |> Enum.with_index(1)

    for {line, i} <- lines,
        not SourceLint.commented?(line),
        not String.contains?(line, "noqa: T3.2"),
        key <- @banned_keys,
        Regex.match?(map_key_regex(key), line) do
      {path, i, key, String.trim(line)}
    end
  end

  # Match either `"key" =>` (string-keyed JSON) or `key:` (atom-keyed) when
  # used as a map field. Anchored with non-word boundary on the left to
  # avoid matching `old_path` when scanning for `path`. The lookahead
  # excludes `path_hmac` etc. — only the bare key counts.
  defp map_key_regex(key) do
    # Negative lookahead `_` prevents `path:` from matching `path_hmac:`.
    # `(?<![A-Za-z_])` left boundary stops `path` from matching `old_path`.
    Regex.compile!(~s/(?<![A-Za-z_])(?:"#{key}"\\s*=>|#{key}:)(?![A-Za-z_])/)
  end
end
