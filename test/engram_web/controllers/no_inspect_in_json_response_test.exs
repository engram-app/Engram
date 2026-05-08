defmodule EngramWeb.NoInspectInJsonResponseTest do
  # T3.0.1 — Static source lint. `inspect(...)` reaching a JSON response
  # body can leak ciphertext, virtual decrypted fields, struct internals,
  # connection strings, hostnames, etc. The original ban was a same-line
  # `json(...inspect(...))` regex; reviewer feedback (PR #73) flagged that
  # `health_controller.ex` was leaking via indirection (the `inspect/1`
  # output was assigned into a map field 12 lines from the `json/2` call).
  #
  # Stronger rule: no `inspect/1` may appear *anywhere* in a controller
  # source file, except inside an explicitly allowlisted context. Keeping
  # error reasons out of HTTP bodies is the value here, not micro-tracking
  # which line they reach.
  use ExUnit.Case, async: true

  alias Engram.Test.SourceLint

  @controllers_dir Path.join([File.cwd!(), "lib/engram_web/controllers"])

  # Allowlisted call contexts where `inspect/1` is fine because the result
  # never reaches a response body.
  @allowed_call_prefixes [
    # Logger metadata is scrubbed by RedactFilter and never serialized.
    "Logger.",
    "Logger ",
    # Telemetry metadata is server-side only.
    ":telemetry.execute",
    "telemetry.execute"
  ]

  # Per-line opt-out marker. Required only for known-safe call sites that
  # the prefix allowlist can't see (e.g. helper definitions invoked exclusively
  # from Logger metadata, or boot-time `raise` calls). Reviewers reject
  # unjustified annotations.
  @allow_marker "noqa: T3.0.6"

  test "no controller calls `inspect/1` outside an allowlisted context" do
    offenders =
      @controllers_dir
      |> SourceLint.walk_ex_files()
      |> Enum.flat_map(&scan_file/1)

    assert offenders == [],
           "Controllers must not call `inspect/1` outside of Logger / telemetry sinks.\n" <>
             "Use `Exception.message/1` for exception structs, or a `format_error/1`\n" <>
             "helper for atom reasons. See health_controller.ex format_error/1.\n" <>
             "If the call is provably safe (Logger-only helper / boot-time raise),\n" <>
             "annotate the line with `# noqa: T3.0.6 — <reason>` AND keep it short.\n\n" <>
             Enum.map_join(offenders, "\n", fn {file, line, snippet} ->
               "  #{Path.relative_to_cwd(file)}:#{line}  #{snippet}"
             end)
  end

  defp scan_file(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _i} ->
      Regex.match?(~r/\binspect\(/, line) and
        not SourceLint.commented?(line) and
        not allowed_context?(line)
    end)
    |> Enum.map(fn {line, i} -> {path, i, String.trim(line)} end)
  end

  defp allowed_context?(line) do
    String.contains?(line, @allow_marker) or
      Enum.any?(@allowed_call_prefixes, fn prefix ->
        String.contains?(line, prefix)
      end)
  end
end
