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
    "lib/engram_web/channels/"
  ]

  # Renders a term rather than a label.
  @unsafe ~r/Exception\.(message|format|format_stacktrace)\(|\binspect\((reason|err|error|other|term|payload|state)\)/

  @sanctioned ["safe_reason", "safe_exit_reason", "format_location"]

  defp in_scope?(path), do: Enum.any?(@content_paths, &String.starts_with?(path, &1))

  # Every `Logger.<level>(...)` call in a file, AND every call to a local log
  # helper, with arguments and line.
  #
  # The helper half is not optional. `crdt_deliver.ex` reads
  # `log_state_load_failure(note_id, Exception.message(err))` — the unsafe
  # rendering happens at the CALL SITE and the `Logger.` call is one function
  # away, so a Logger-only scan walked straight past it. That was verified by
  # reverting that exact line and watching this test stay green.
  defp log_calls(source) do
    Regex.scan(
      ~r/(?:Logger\.(?:error|warning|warn|info|debug)|log_[a-z_]+|emit_[a-z_]*(?:failure|error))\(/,
      source,
      return: :index
    )
    |> Enum.map(fn [{start, len} | _] ->
      args = balanced_args(source, start + len)
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {line, args}
    end)
  end

  defp balanced_args(source, from) do
    size = byte_size(source)

    Enum.reduce_while(from..(size - 1)//1, {1, from}, fn i, {depth, _} ->
      case binary_part(source, i, 1) do
        "(" -> {:cont, {depth + 1, i}}
        ")" when depth == 1 -> {:halt, {0, i}}
        ")" -> {:cont, {depth - 1, i}}
        _ -> {:cont, {depth, i}}
      end
    end)
    |> case do
      {0, stop} -> binary_part(source, from, stop - from)
      # Unbalanced: hand back the rest, which errs toward flagging.
      {_, _} -> binary_part(source, from, size - from)
    end
  end

  test "no log call on a content path renders a raw exception or reason" do
    files =
      Path.wildcard("lib/**/*.ex")
      |> Enum.filter(&in_scope?/1)

    # Vacuity: a guard over zero files proves nothing, and this project has
    # shipped exactly that.
    assert length(files) > 20,
           "expected the content-module list to match real files, got #{length(files)}"

    in_calls =
      for file <- files,
          source = File.read!(file),
          {line, args} <- log_calls(source),
          not Enum.any?(@sanctioned, &String.contains?(args, &1)),
          match = Regex.run(@unsafe, args),
          do: "#{file}:#{line} — #{hd(match)}"

    # Indirection through a local defeats the call-site scan:
    # `reason_str = inspect(reason)` a few lines above, then `reason: reason_str`
    # inside the Logger call. attachments.ex did exactly that, into both the
    # message body and unscrubbed metadata, and the scan above walked past it.
    in_bindings =
      for file <- files,
          source = File.read!(file),
          {line, text} <-
            Enum.with_index(String.split(source, "\n"), 1) |> Enum.map(fn {l, i} -> {i, l} end),
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
