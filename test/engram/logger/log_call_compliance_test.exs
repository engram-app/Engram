defmodule Engram.Logger.LogCallComplianceTest do
  @moduledoc """
  No module that handles note content may render a raw exception or reason into
  a log line.

  `RedactFilter` scrubs metadata BY KEY and never touches the message body — it
  says so in its own moduledoc. `:error`, `:reason` and `:message`, the three
  keys these call sites reach for, are all absent from its key set. So both
  halves of a `Logger.warning(body, metadata)` on these paths are unfiltered,
  and prod's formatter (`{:all_except, [...]}`) emits every metadata key.

  What gets rendered there is the problem. `Exception.message/1` returns
  `inspect(term)` for `CaseClauseError`, `MatchError`, `KeyError`,
  `Protocol.UndefinedError` and `Jason.EncodeError`; `Exception.format/3` and
  `Exception.format_stacktrace/1` additionally print the failing call's ARGUMENT
  LIST at `:printable_limit` (4096 bytes); and an exit reason is
  `{exception, stacktrace}` or `{:timeout, {GenServer, :call, [pid, request, _]}}`.
  On these modules those terms are note bodies, paths, titles, search queries
  and Yjs frames.

  `Engram.Logger.Metadata.safe_reason/1`, `safe_exit_reason/1` and
  `format_location/1` exist for this. This test is what makes using them the
  default rather than something each rescue has to remember.

  ## Why a source guard rather than per-site tests

  A 2026-08-16 review reverted three converted rescues SIMULTANEOUSLY and the
  full suite stayed green — those paths are deep in rescue arms that are hard to
  provoke, so nothing pinned them. A text guard pins all of them at once and,
  unlike a per-site test, also catches the site added next week.

  It is a text guard, so it is not a proof. It cannot see through a helper
  (`log_it(Exception.message(e))`), and it only knows the variable names this
  codebase actually uses. It is the cheap net; `metadata_safe_reason_test.exs`
  is where the behaviour itself is proven.
  """
  use ExUnit.Case, async: true

  # Modules where note content, a path, a title or a search query is in scope.
  # Deliberately NOT all of lib/: the same shape in `accounts/lifecycle.ex` or
  # `workers/export_expiry_sweep.ex` cannot reach note data, and a guard that
  # flags 84 sites to protect 40 gets switched off. Widen this list rather than
  # adding exceptions to it.
  @content_paths [
    "lib/engram/notes.ex",
    "lib/engram/notes/",
    "lib/engram/attachments.ex",
    "lib/engram/crypto/",
    "lib/engram/logs.ex",
    "lib/engram/links/",
    "lib/engram/rerankers/",
    "lib/engram_web/channels/",
    # Added after review: each of these has note content, a path, a title or a
    # search query in scope, and each was outside the first list purely because
    # the list was written from the files that session had open. A scope list
    # assembled from memory covers what you remember, which is not what leaks.
    "lib/engram/attachments/",
    "lib/engram/links.ex",
    "lib/engram/workers/backfill_crdt_state.ex",
    "lib/engram/workers/checkpoint_note.ex",
    "lib/engram/workers/project_vault_index.ex",
    "lib/engram/workers/embed_note.ex",
    "lib/engram/workers/delete_note_index.ex",
    "lib/engram/workers/repath_note_index.ex",
    "lib/engram/workers/reindex_keyword.ex",
    "lib/engram_web/controllers/search_controller.ex",
    "lib/engram_web/controllers/notes_controller.ex",
    # Second widening, from a deliberate audit of the 311 files the list did
    # NOT cover rather than from the files a session happened to have open.
    # `storage/s3.ex` is the one that proved the point: `storage_key:` is in
    # RedactFilter's key set and came out `[REDACTED]`, while the SAME vault
    # path rode through unredacted inside `reason:` in the same call. A
    # key-based redactor cannot catch a value travelling under another name.
    "lib/engram/storage/",
    "lib/engram/indexing.ex",
    "lib/engram/crypto.ex",
    "lib/engram_web/controllers/attachments_controller.ex",
    "lib/engram/backfill/",
    "lib/engram/mcp/",
    "lib/engram/vaults.ex"
  ]

  # Renders a term rather than a label. `e` is in the list because `rescue e ->`
  # is the idiomatic binding and `inspect(e)` was therefore the single most
  # likely shape to appear next — it was missing from the first version.
  @unsafe ~r/Exception\.(message|format|format_stacktrace)\(|\binspect\((reason|err|error|e|other|term|payload|state)\)/

  @sanctioned ["safe_reason", "safe_exit_reason", "format_location"]

  defp in_scope?(path), do: Enum.any?(@content_paths, &String.starts_with?(path, &1))

  # Every `Logger.<level>(...)` call in a file, AND every call to a local log
  # helper, with arguments and line.
  #
  # `:telemetry.execute/3` is in the list because its third argument is
  # METADATA that reaches PromEx and Sentry handlers — it is a sink, even though
  # nothing about the call says "log". `indexing.ex` was putting
  # `reason: inspect(reason)` into an `encrypt_failed` event and the
  # Logger-only scan walked straight past it; verified by reverting that line
  # and watching this test stay green.
  #
  # The helper half is not optional. `crdt_deliver.ex` reads
  # `log_state_load_failure(note_id, Exception.message(err))` — the unsafe
  # rendering happens at the CALL SITE and the `Logger.` call is one function
  # away, so a Logger-only scan walked straight past it. That was verified by
  # reverting that exact line and watching this test stay green.
  defp log_calls(source) do
    Regex.scan(
      ~r/(?:Logger\.(?:error|warning|warn|info|debug)|log_[a-z_]+|emit_[a-z_]*(?:failure|error)|:telemetry\.execute)\(/,
      source,
      return: :index
    )
    |> Enum.map(fn [{start, len} | _] ->
      args = balanced_args(source, start + len)
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {line, args}
    end)
  end

  # String-aware. A `")"` inside a message literal — `Logger.warning("done :)")`
  # — decremented the depth and truncated the argument span early, so anything
  # after it in the call was never inspected. Unterminated or exotic quoting
  # falls through to "hand back the rest", which errs toward flagging.
  defp balanced_args(source, from) do
    size = byte_size(source)

    Enum.reduce_while(from..(size - 1)//1, {1, from, false}, fn i, {depth, _, in_str} ->
      char = binary_part(source, i, 1)
      escaped? = i > 0 and binary_part(source, i - 1, 1) == "\\"

      cond do
        escaped? -> {:cont, {depth, i, in_str}}
        char == ~s(") -> {:cont, {depth, i, not in_str}}
        in_str -> {:cont, {depth, i, in_str}}
        char == "(" -> {:cont, {depth + 1, i, in_str}}
        char == ")" and depth == 1 -> {:halt, {0, i, in_str}}
        char == ")" -> {:cont, {depth - 1, i, in_str}}
        true -> {:cont, {depth, i, in_str}}
      end
    end)
    |> case do
      {0, stop, _} -> binary_part(source, from, stop - from)
      {_, _, _} -> binary_part(source, from, size - from)
    end
  end

  @doc false
  # The units a sanctioned call may vouch for: each `\#{...}` interpolation on
  # its own, plus whatever is left after the interpolations and string literals
  # are stripped out (the metadata keyword list — `reason: inspect(reason)`
  # lives there, outside any interpolation).
  #
  # Per-UNIT, not per-call. `@sanctioned` used to exempt the entire argument
  # span if the word appeared anywhere in it, so
  #
  #     "note=\#{safe_reason(e)} raw=\#{inspect(reason)}"
  #
  # was clean by the guard's own reckoning: one safe interpolation vouched for
  # its unsafe sibling. Review flagged it; the fix is that a unit can only
  # vouch for itself.
  def units(args) do
    interps = balanced_interpolations(args)
    [strip_interpolations_and_strings(args) | interps]
  end

  # `Logger.info("x")` has a zero-length argument span once stripped, and
  # `0..-1//1` is not empty in Elixir — it iterates once and crashed on
  # `binary_part("", 0, 1)`.
  defp balanced_interpolations(text) when byte_size(text) < 2, do: []

  defp balanced_interpolations(text) do
    size = byte_size(text)

    Enum.reduce(0..max(size - 2, 0)//1, {[], nil, 0}, fn i, {acc, start, depth} ->
      two = binary_part(text, i, min(2, size - i))
      char = binary_part(text, i, 1)

      cond do
        is_nil(start) and two == "\#{" -> {acc, i + 2, 1}
        is_nil(start) -> {acc, start, depth}
        char == "{" -> {acc, start, depth + 1}
        char == "}" and depth == 1 -> {[binary_part(text, start, i - start) | acc], nil, 0}
        char == "}" -> {acc, start, depth - 1}
        true -> {acc, start, depth}
      end
    end)
    |> elem(0)
  end

  defp strip_interpolations_and_strings(text) do
    text
    |> String.replace(~r/\#\{(?:[^{}]|\{[^{}]*\})*\}/, " ")
    |> String.replace(~r/"(?:[^"\\]|\\.)*"/, ~s(""))
  end

  # Lines to scan for a `reason = <unsafe>` binding, with a continuation folded
  # onto its opener.
  #
  # `mix format` wraps a long binding, and the wrapped form was invisible:
  #
  #     reason_str =
  #       inspect(reason)
  #
  # The opener has no `inspect(` on it and the continuation has no `=`, so a
  # strictly per-line scan matched neither half — and the formatter decides
  # which bindings get wrapped, so whether this guard saw a site came down to
  # how long its variable name was.
  defp binding_lines(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.map(fn {text, i} -> {i, text} end)
    |> then(fn lines ->
      folded =
        Enum.zip(lines, Enum.drop(lines, 1) ++ [{0, ""}])
        |> Enum.map(fn {{i, text}, {_, next}} ->
          if Regex.match?(~r/=\s*$/, text),
            do: {i, text <> " " <> String.trim(next)},
            else: {i, text}
        end)

      folded
    end)
  end

  test "no log call on a content path renders a raw exception or reason" do
    files =
      Path.wildcard("lib/**/*.ex")
      |> Enum.filter(&in_scope?/1)

    # Vacuity. `length(files) > 20` was too weak to be worth writing: the
    # directory prefixes alone clear it, so a typo in any single-FILE entry
    # ("lib/engram/lnks.ex") silently dropped that module from the scan while
    # the assert stayed comfortably green. Every literal path is now checked to
    # exist, which is the property actually wanted — the list is a coverage
    # claim, and a claim naming a file that is not there is a false one.
    missing = Enum.reject(@content_paths, &(File.exists?(&1) or String.ends_with?(&1, "/")))
    assert missing == [], "content-module list names files that do not exist: #{inspect(missing)}"

    missing_dirs =
      Enum.filter(@content_paths, &(String.ends_with?(&1, "/") and not File.dir?(&1)))

    assert missing_dirs == [], "content-module list names missing dirs: #{inspect(missing_dirs)}"

    assert length(files) > 20,
           "expected the content-module list to match real files, got #{length(files)}"

    in_calls =
      for file <- files,
          source = File.read!(file),
          {line, args} <- log_calls(source),
          unit <- units(args),
          not Enum.any?(@sanctioned, &String.contains?(unit, &1)),
          match = Regex.run(@unsafe, unit),
          do: "#{file}:#{line} — #{hd(match)}"

    # Indirection through a local defeats the call-site scan:
    # `reason_str = inspect(reason)` a few lines above, then `reason: reason_str`
    # inside the Logger call. attachments.ex did exactly that, into both the
    # message body and unscrubbed metadata, and the scan above walked past it.
    in_bindings =
      for file <- files,
          source = File.read!(file),
          {line, text} <- binding_lines(source),
          not Enum.any?(@sanctioned, &String.contains?(text, &1)),
          not String.starts_with?(String.trim(text), "#"),
          Regex.match?(~r/^\s*\w*(reason|err|error|msg|message)\w*\s*=\s*/, text),
          match = Regex.run(@unsafe, text),
          do: "#{file}:#{line} — #{hd(match)} bound to a local"

    findings = in_calls ++ in_bindings

    assert findings == [],
           """
           These log calls render a term rather than a label, on modules where
           note content is in scope. Use Engram.Logger.Metadata.safe_reason/1
           (or safe_exit_reason/1 in a `catch :exit` arm, or format_location/1
           for a stacktrace):

           #{Enum.join(findings, "\n")}
           """
  end
end
