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
  # `billing/` cannot reach note data, and a guard that
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
    "lib/engram/vaults.ex",
    # Third widening. Review checked the previous one and found `workers/` held
    # the very defect this change is named after — `storage_key:` redacted by
    # name while the same vault path rode inside `reason:` — in
    # `cleanup_vault.ex`. The rest are clean today and are netted so they stay
    # that way; `folders.ex` is the constraint's own `Medical/` example and was
    # somehow still not listed after two passes.
    "lib/engram/workers/",
    "lib/engram/folders.ex",
    "lib/engram/search.ex",
    "lib/engram/search/",
    "lib/engram/sync.ex",
    "lib/engram/storage.ex",
    "lib/engram/vaults/",
    "lib/engram/vector/",
    "lib/engram/keyword_index.ex",
    "lib/engram/embedder.ex",
    "lib/engram/embedders/",
    # Fourth widening, from the deny-list work below: `reranker.ex` sees search
    # queries (its `rerankers/` siblings were already in scope) and
    # `request_logger.ex` logs request paths.
    "lib/engram/reranker.ex",
    "lib/engram/sync/",
    "lib/engram/keyword_index/",
    "lib/engram/accounts/export/",
    "lib/engram_web/request_logger.ex",
    # Clean today, netted so they stay that way: the markdown parser IS note
    # content, content-hash backfill reads it, and `logs/client_log.ex` is the
    # schema for the plugin's own log lines.
    "lib/engram/parsers/",
    "lib/engram/content_hash/",
    "lib/engram/logs/"
  ]

  # Everything in `lib/` that is deliberately NOT scanned, with the reason.
  #
  # The scope list above was an ALLOWLIST, and widening it found real leaks FOUR
  # separate times — `storage/s3.ex`, `cleanup_vault.ex`, `folders.ex` (the
  # constraint's own `Medical/` example, missed twice) and `reranker.ex`. Four
  # for four is not a list converging on complete; it is a list whose default is
  # wrong.
  #
  # So the default is inverted here: `every_file_is_classified` fails on any
  # file matching NEITHER list. A new module cannot be silently uncovered — it
  # has to be put in scope or written down here with a reason. That turns an
  # omission into a decision.
  @out_of_scope [
    # Auth, identity and OAuth — tokens and emails, never note data.
    "lib/engram/abuse/",
    "lib/engram/auth.ex",
    "lib/engram/auth/",
    "lib/engram/auth/clerk/",
    "lib/engram/auth/providers/",
    "lib/engram/connections.ex",
    "lib/engram/connections/",
    "lib/engram/invites.ex",
    "lib/engram/invites/",
    "lib/engram/oauth.ex",
    "lib/engram/oauth/",
    "lib/engram/oauth/cimd/",
    "lib/engram/token.ex",
    "lib/engram_web/oauth_metadata.ex",

    # Billing and payments — Paddle, plans, meters.
    "lib/engram/billing.ex",
    "lib/engram/billing/",
    "lib/engram/billing/workers/",
    "lib/engram/conversation_meter.ex",
    "lib/engram/legal.ex",
    "lib/engram/legal/",
    "lib/engram/legal/version_cache/",
    "lib/engram/onboarding.ex",
    "lib/engram/onboarding/",
    "lib/engram/paddle/",
    "lib/engram/paddle/client/",
    "lib/engram/usage/",
    "lib/engram/usage/daily_cap/",
    "lib/engram/usage_meters.ex",
    "lib/engram/usage_meters/",

    # Web plumbing — routing, plugs, schemas, sockets. Request PATHS are handled
    # in `request_logger.ex`, which IS in scope.
    "lib/engram/webhooks/",
    "lib/engram_web.ex",
    "lib/engram_web/api_spec.ex",
    "lib/engram_web/controllers/",
    "lib/engram_web/controllers/admin/",
    "lib/engram_web/csp.ex",
    "lib/engram_web/endpoint.ex",
    "lib/engram_web/gettext.ex",
    "lib/engram_web/limit_response.ex",
    "lib/engram_web/origin_device.ex",
    "lib/engram_web/plugs/",
    "lib/engram_web/presence.ex",
    "lib/engram_web/rate_limiter.ex",
    "lib/engram_web/rate_limiter/",
    "lib/engram_web/remote_ip.ex",
    "lib/engram_web/request_meta.ex",
    "lib/engram_web/router.ex",
    "lib/engram_web/schemas.ex",
    "lib/engram_web/schemas/",
    "lib/engram_web/telemetry.ex",
    "lib/engram_web/user_socket.ex",
    "lib/engram_web/webhooks/",

    # Observability and telemetry — counters and traces by construction.
    "lib/engram/logger/",
    "lib/engram/observability/",
    "lib/engram/prom_ex.ex",
    "lib/engram/prom_ex/",
    "lib/engram/spa_integrity.ex",
    "lib/engram/telemetry.ex",
    "lib/engram/telemetry/",

    # Infrastructure and runtime — no note data reaches these.
    "lib/engram.ex",
    "lib/engram/accounts.ex",
    "lib/engram/accounts/",
    "lib/engram/application.ex",
    "lib/engram/aws/",
    "lib/engram/aws_kms.ex",
    "lib/engram/aws_kms/",
    "lib/engram/cache/",
    "lib/engram/cluster/",
    "lib/engram/drainer.ex",
    "lib/engram/email/",
    "lib/engram/http/",
    "lib/engram/idempotency.ex",
    "lib/engram/idempotency/",
    "lib/engram/instance.ex",
    "lib/engram/instance/",
    "lib/engram/mailer.ex",
    "lib/engram/oban_facade.ex",
    "lib/engram/release.ex",
    "lib/engram/release/",
    "lib/engram/repo.ex",
    "lib/engram/runtime_config.ex",
    "lib/engram/schema.ex",
    "lib/engram/secrets.ex",
    "lib/engram/service_config.ex",
    "lib/engram/tenant_error.ex",

    # Mix tasks — operator tooling, run by hand.
    "lib/mix/tasks/",

    # Redaction implementations. In scope would be circular — these ARE the
    # controls, and `sentry/scrubber.ex` has its own test asserting note data
    # never reaches Sentry.
    "lib/engram/sentry/",

    # Host/URL configuration — public hostnames, no note data.
    "lib/engram/host_origins.ex"
  ]

  # Renders a term rather than a label. `e` is in the list because `rescue e ->`
  # is the idiomatic binding and `inspect(e)` was therefore the single most
  # likely shape to appear next — it was missing from the first version.
  # `(?![.\\w])` after each carrier, applied where these are interpolated below.
  # A carrier FOLLOWED BY A FIELD ACCESS is a scalar, not the term:
  # `inspect(note.id)`, `inspect(att.id)`, `inspect(e.__struct__)`,
  # `inspect(changeset.valid?)`. Without it the per-key split turns
  # `rerankers/jina.ex:65` red for a line that is correct, which is how a guard
  # earns being switched off.
  #
  # It does NOT exclude a carrier wrapped in a CALL — `inspect(byte_size(content))`
  # and `inspect(length(result))` are safe and would flag, because `)` is neither
  # `.` nor a word character. None occur in scope today; if one appears the
  # answer is to name the wrapper in @sanctioned, not to widen this. An earlier
  # version of this comment claimed that shape was handled.
  @carriers "reason|err|error|e|other|term|payload|state|unexpected|result|resp|res|changeset|att|note|content"

  # Anchored on `inspect(` REACHING a carrier, not on `inspect(carrier)` exactly.
  # Review's table of misses was all near-hits on the old shape:
  #
  #   inspect(%{outer: %{reason: reason}})   nested in a map
  #   inspect(reason, limit: 50)             a second argument
  #   reason |> inspect()                    piped
  #   inspect reason                         no parens
  #
  # Each renders the term just as completely as `inspect(reason)`. `\b` around
  # each carrier keeps `error_kind` and `note_id` from matching, since `_` is a
  # word character.
  @unsafe ~r/Exception\.(message|format|format_stacktrace)\(|\binspect\([^)]{0,120}\b(#{@carriers})\b(?![.\w])|\b(#{@carriers})\b(?![.\w])\s*\|>\s*inspect\b|\binspect\s+(#{@carriers})\b(?![.\w])/

  # `error_kind/1` (Engram.Telemetry) is a label renderer exactly like
  # `safe_reason/1`: every clause returns an atom or a module — the term itself
  # when it is already an atom, the tuple TAG, the exception struct name, or
  # `:other`. `inspect/1` around it therefore renders a label, not the payload.
  # `prepare_error_kind/1` in crdt_channel delegates straight to it.
  @doc false
  def unsafe_pattern, do: @unsafe

  @sanctioned [
    "safe_reason",
    "safe_exit_reason",
    "format_location",
    "error_kind",
    # Delegates straight to error_kind/1 (crdt_channel.ex:1196). Listed
    # explicitly because sanctioned names now have to match as CALLS with a
    # word boundary — which is the point: it stops an impostor
    # `error_kind_of/1` vouching by substring, but it also stops a legitimate
    # wrapper doing so, so real wrappers get named here.
    "prepare_error_kind"
  ]

  defp in_scope?(path), do: Enum.any?(@content_paths, &String.starts_with?(path, &1))

  # A sanctioned name only vouches when it is CALLED, and comments never vouch.
  #
  # `String.contains?` over the raw unit meant `error_kind: inspect(reason)`
  # was clean because the KEY NAME matched — and `error_kind:` is an
  # established metadata key here, so that is a realistic mistake, not a
  # contrived one. A comment mentioning `safe_reason` above the line did the
  # same, and so would an impostor `error_kind_of/1` returning the raw term.
  def sanctioned?(unit) do
    unit
    |> strip_comments_and_strings()
    |> then(&Regex.match?(~r/\b(#{Enum.join(@sanctioned, "|")})\(/, &1))
  end

  # Comments and string literals never vouch.
  #
  # Line-based rejection only caught a comment on its OWN line, so
  # `reason: inspect(reason) # prefer safe_reason(e)` was exempt — and a string
  # literal mentioning the name did the same. Strip from `#` to end-of-line
  # wherever it appears.
  defp strip_comments_and_strings(text) do
    text
    |> String.replace(~r/"(?:[^"\\]|\\.)*"/, ~s(""))
    |> strip_comments()
  end

  # `#` to end of line, except `#{` which opens an interpolation.
  defp strip_comments(text), do: String.replace(text, ~r/#(?!\{)[^\n]*/, "")

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
    # Comments are stripped ONCE, here, over the whole span.
    #
    # Doing it inside `keyword_follows?/2` needed a lookahead window, and a
    # comment run LONGER than that window left the window ending mid-comment:
    # no `key:` matched, no split, and the keys merged back into one unit —
    # sibling-vouching again, one comment deeper. This repo writes 400-800 char
    # comment blocks inside log calls (`attachments_controller.ex:342`,
    # `crdt_channel.ex:144`), so no window was ever going to be big enough.
    #
    # It also fixes the mirror-image failure: prose in a comment could TRIGGER
    # the `@unsafe` match while never being able to silence it, so
    # `# do NOT switch this to inspect(reason)` turned the guard red on correct
    # code. The two were masking each other; stripping once cures both.
    #
    # COMMENTS only — stripping string literals here would blank the very
    # interpolations `balanced_interpolations/1` exists to find. Strings are
    # stripped further down, in `metadata_units/1`, where that is correct.
    stripped = strip_comments(args)

    balanced_interpolations(stripped) ++ metadata_units(stripped)
  end

  # The non-interpolated leftover, split per `key: value`.
  #
  # It used to be handed back as ONE string, so one `safe_reason` anywhere in a
  # keyword list exempted every other key in it — verbatim the sibling-vouching
  # defect the per-unit split was introduced to fix, just moved. Worse, this
  # series ENLARGED it: every site converted here now contains the sanctioned
  # literal, which permanently exempted its whole metadata list. Review measured
  # 52 of 292 in-scope calls self-exempt, a number that grew because of the fix.
  #
  # Split on top-level commas only — a nested `inspect(%{a: 1, b: 2})` or a call
  # with several arguments must not be torn into fragments that match nothing.
  def metadata_units(args) do
    args
    |> strip_interpolations_and_strings()
    |> split_top_level_commas()
  end

  # Split a keyword list into one unit per `key: value`.
  #
  # The previous version split on commas at bracket depth 0 — and essentially
  # every in-scope call writes its metadata as
  # `Metadata.with_category(:error, :sync, k1: v1, k2: v2)`, where those commas
  # sit at depth 1. So it split nothing that exists and the keyword list stayed
  # one unit, leaving one sanctioned key vouching for all its siblings: the
  # same defect as the round before, moved one paren deeper. It moved the
  # measured count from 52 self-exempt calls to 50.
  #
  # Depth <= 1 AND the next token must look like `key:`. Both halves matter:
  # depth alone would tear `inspect(%{a: 1, b: 2})` into fragments that match
  # nothing, and the `key:` lookahead alone would split argument lists.
  def split_top_level_commas(text) do
    graphemes = String.graphemes(text)

    graphemes
    |> Enum.with_index()
    |> Enum.reduce({[], [], 0}, fn {ch, i}, {done, cur, depth} ->
      cond do
        ch in ["(", "{", "["] ->
          {done, [ch | cur], depth + 1}

        ch in [")", "}", "]"] ->
          {done, [ch | cur], depth - 1}

        ch == "," and depth <= 1 and keyword_follows?(graphemes, i + 1) ->
          {[cur |> Enum.reverse() |> Enum.join() | done], [], depth}

        true ->
          {done, [ch | cur], depth}
      end
    end)
    |> then(fn {done, cur, _} -> [cur |> Enum.reverse() |> Enum.join() | done] end)
  end

  # Does a `key:` follow this comma? Comments are already gone by here (see
  # `units/1`), so a small fixed window suffices — the widest real comma-to-key
  # gap in scope is 25.
  #
  # The previous version skipped comment lines inside a 400-grapheme window,
  # and a comment run LONGER than the window left it ending mid-comment: no
  # `key:` matched, no split, and the keys merged back into one unit. This repo
  # writes 400-800 char comment blocks inside log calls, so that window was
  # never going to be big enough. Stripping once in `units/1` removes the
  # problem instead of sizing around it.
  def keyword_follows?(graphemes, from) do
    graphemes
    |> Enum.drop(from)
    # Leading whitespace does not count against the window. `strip_comments/1`
    # removes comment TEXT but leaves the newline and each line's indentation,
    # so a two-line comment block at this repo's 10-space log indent puts 33
    # whitespace characters before the key — past a 40-char window once the key
    # name is included. Measured gaps of 33, 45 and 91 at `jina.ex:65`,
    # `rewrite_note_links.ex:337` and `attachments_controller.ex:342`; the
    # comment claiming "the widest real gap is 25" was measuring the wrong
    # thing.
    |> Enum.drop_while(&(&1 in [" ", "\t", "\n", "\r"]))
    |> Enum.take(40)
    |> Enum.join()
    |> then(&Regex.match?(~r/^\s*[a-z_][a-zA-Z0-9_]*:/, &1))
  end

  # Every `#{...}` body in a template, at arbitrary nesting depth.
  #
  # This is the hand-rolled scanner restored with TWO fixes, having twice been
  # wrong here:
  #
  #   * it seeded depth to 1 on the `#`, then the loop re-read the `{` of `#{`
  #     and made it 2 — so the `depth == 1` push arm could never fire and this
  #     returned [] for everything. The guard was blind to every message body.
  #   * the range stopped at `size - 2`, so the final byte was never visited and
  #     a template ENDING in `}` — which is most of them — was missed even after
  #     the seed was fixed.
  #
  # The regex that briefly replaced it was worse: `(?:[^{}]|\{[^{}]*\})*` caps
  # out at one level of nesting, and on two levels the span was not merely
  # unparsed but ERASED — `strip_interpolations_and_strings/1` failed to strip
  # it and its string-literal rule then swallowed the text, so it landed in no
  # unit at all. A counter has no depth limit.
  def balanced_interpolations(text) when byte_size(text) < 2, do: []

  def balanced_interpolations(text) do
    size = byte_size(text)

    Enum.reduce(0..(size - 1)//1, {[], nil, 0}, fn i, {acc, start, depth} ->
      two = if i + 2 <= size, do: binary_part(text, i, 2), else: ""
      char = binary_part(text, i, 1)

      cond do
        is_nil(start) and two == "\#{" -> {acc, i + 2, 0}
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

  # The inversion. Without this the scope list is a wish; with it, a new module
  # is a build failure until someone classifies it.
  test "every file in lib/ is classified as in-scope or explicitly excluded" do
    unclassified =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(fn f ->
        Enum.any?(@content_paths, &String.starts_with?(f, &1)) or
          Enum.any?(@out_of_scope, &String.starts_with?(f, &1))
      end)

    assert unclassified == [],
           """
           These files are in neither list. Decide which:

           * it can reach note content, a path, a title or a search query
             -> add it to @content_paths, and fix whatever the scan then finds
           * it cannot -> add it to @out_of_scope with the reason

           Do not add it to @out_of_scope to make this pass. The allowlist that
           preceded this test hid real leaks in four separate modules.

           #{Enum.join(unclassified, "\n")}
           """
  end

  # A stale entry is a coverage claim about a file that no longer exists.
  test "no classification entry is stale" do
    for entry <- @content_paths ++ @out_of_scope do
      exists? = if String.ends_with?(entry, "/"), do: File.dir?(entry), else: File.exists?(entry)
      assert exists?, "classification names a path that does not exist: #{entry}"
    end
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
          not sanctioned?(unit),
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
          not sanctioned?(text),
          not String.starts_with?(String.trim(text), "#"),
          # Any identifier, not just one whose NAME says "reason". `detail =
          # inspect(reason)` a few lines above a Logger call is the same
          # indirection and was invisible.
          Regex.match?(~r/^\s*[a-z_][a-zA-Z0-9_]*\s*=\s*/, text),
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

  # The helpers, tested directly.
  #
  # Every previous version of this guard was broken in a way the LIVE scan could
  # not reveal: a scanner that always returned [], a splitter that split nothing
  # the codebase writes. Both passed because the tree happened to be clean, and
  # both were only caught by review. Replacing `split_top_level_commas/1` with
  # `List.wrap/1` — its pre-fix behaviour — left the whole suite green.
  #
  # These pin the mechanism instead of the tree, so the next regression fails
  # here rather than waiting for a leak to walk past.
  describe "units/1 mechanics" do
    test "a with_category keyword list splits per key" do
      args =
        ~s|"msg", Metadata.with_category(:error, :sync, a: inspect(reason), b: safe_reason(x))|

      units = units(args)

      assert Enum.any?(units, &(&1 =~ "inspect(reason)" and not (&1 =~ "safe_reason"))),
             "the unsafe key must be its own unit, got: #{inspect(units)}"
    end

    # A COMMENT between two keys stopped the split and merged them back, so the
    # sanctioned key vouched for its sibling again. This is the house style —
    # 5 in-scope calls were self-exempt for exactly this reason.
    test "a comment line between keys does not merge them" do
      args =
        ~s|"msg", Metadata.with_category(:error, :sync, a: inspect(reason),\n  # why we do this\n  b: safe_reason(x))|

      units = units(args)

      assert Enum.any?(units, &(&1 =~ "inspect(reason)" and not (&1 =~ "safe_reason("))),
             "comment merged the keys back into one unit: #{inspect(units)}"
    end

    # A TWO-LINE comment block at this repo's real 10-space log indent.
    #
    # `strip_comments/1` removes the comment text but leaves the newline and
    # each line's indentation, so this puts 33 whitespace characters between
    # the comma and the key — past a 40-char window once the key name is
    # counted. The single-short-comment case below was calibrated under the
    # real threshold and so could not tell a 40-char window from a 400-char
    # one; three live sites were mis-split while it stayed green.
    test "a multi-line comment block at real indentation still splits" do
      args =
        "\"msg\", Metadata.with_category(:error, :sync, a: inspect(reason)," <>
          "\n          # first line of explanation" <>
          "\n          # second line of explanation" <>
          "\n          message: safe_reason(x))"

      units = units(args)

      assert Enum.any?(units, &(&1 =~ "inspect(reason)" and not (&1 =~ "safe_reason("))),
             "a real-width comment block merged the keys: #{inspect(units)}"
    end

    # Pins `keyword_follows?/2` itself: a comma NOT followed by a key must not
    # split. Previously nothing exercised this — replacing the function with
    # `true` left the suite green.
    test "a comma inside an argument list is not a key boundary" do
      refute keyword_follows?(String.graphemes("inspect(a, b)"), 10)
      assert keyword_follows?(String.graphemes(", note_id: x"), 1)
      # NOT a comment case: comments are gone before this is called (units/1),
      # so this function deliberately does not know about them.
      refute keyword_follows?(String.graphemes(", inspect(x)"), 1)
    end

    test "a comma inside a nested map does not split" do
      units = units(~s|"msg", m: inspect(%{a: 1, b: 2})|)

      assert Enum.any?(units, &(&1 =~ "%{a: 1, b: 2}")),
             "nested map was torn apart: #{inspect(units)}"
    end

    test "interpolations are returned whole, at any nesting depth" do
      assert "inspect(reason)" in units(~s|"a=\#{inspect(reason)}"|)
      assert "inspect(%{k: %{j: %{n: 1}}})" in units(~s|"a=\#{inspect(%{k: %{j: %{n: 1}}})}"|)
    end

    # Pins the scanner's range. It ran to `size - 2` and so never visited the
    # final byte, missing every template ENDING in `}` — which is most of them.
    test "an interpolation at the very end of a template is found" do
      assert balanced_interpolations(~s|a=\#{x}|) == ["x"]
    end

    test "adjacent interpolations are separate units" do
      units = units(~s|"\#{a} and \#{b}"|)

      assert "a" in units
      assert "b" in units
    end
  end

  # Pins `(?![.\w])`. Without it a field access on a carrier is flagged, and
  # `rerankers/jina.ex:65` — correct code — goes red. That is the "flags safe
  # code, gets switched off" failure.
  describe "@unsafe carrier boundary" do
    test "a field access on a carrier is not a leak" do
      for safe <- ["inspect(note.id)", "inspect(e.__struct__)", "inspect(att.id)"] do
        refute Regex.match?(unsafe_pattern(), safe), "false positive on #{safe}"
      end
    end

    test "the bare carrier still is" do
      for leak <- ["inspect(reason)", "inspect(e)", "reason |> inspect()", "inspect reason"] do
        assert Regex.match?(unsafe_pattern(), leak), "missed #{leak}"
      end
    end
  end

  describe "sanctioned?/1" do
    test "vouches only for a CALL, never a key name, comment or string" do
      refute sanctioned?("error_kind: inspect(reason)")
      refute sanctioned?("error_kind_of(reason)")
      # Comment stripping: these DO contain `safe_reason(`, so they pin it.
      refute sanctioned?("# use safe_reason(e) here\n raw: inspect(reason)")
      refute sanctioned?(~s|raw: inspect(reason) # prefer safe_reason(e)|)
      refute sanctioned?(~s|raw: inspect(reason) <> "see safe_reason(e)"|)

      assert sanctioned?("reason: Metadata.safe_reason(reason)")
      assert sanctioned?("inspect(Engram.Telemetry.error_kind(reason))")
    end
  end

  # What this guard does NOT catch, as executable record.
  #
  # Review produced these across eight rounds. Left in a transcript they are
  # folklore; here they are checked, so if one starts being caught the test
  # goes red and someone deletes a line instead of wondering. Equally, nobody
  # can claim coverage this guard does not have — which is how every leak in
  # this series survived.
  #
  # None occurs in `lib/` today; that was swept per-shape.
  describe "documented blind spots" do
    test "to_string/1 renders a term and is not matched" do
      refute Regex.match?(unsafe_pattern(), "to_string(reason)"),
             "to_string is now caught — delete this test and say so in the moduledoc"
    end

    # `log_calls/1` anchors on `Logger.*`, `log_*` and `emit_*(failure|error)`.
    # A helper named anything else hides its argument one call away.
    test "a helper outside the naming convention is not scanned" do
      calls = log_calls(~s|def f(r), do: report_problem("x", inspect(r))|)

      assert calls == [], "helper naming is now scanned — widen the doc, not just the regex"
    end

    # `balanced_args/2` is string-aware for `"` only.
    test "a ~s sigil truncates the argument span" do
      args = balanced_args(~s|Logger.error(~s(a)b), inspect(reason))|, 13)

      refute args =~ "inspect(reason)",
             "sigils are now handled — this blind spot is closed"
    end

    # Both scans are per-file. A value assembled in another module, or a
    # binding more than one hop from the log call, is invisible.
    test "cross-module indirection is out of reach by construction" do
      # Recorded rather than asserted: there is no regex that closes this.
      # `Metadata.safe_reason/1` at the call site is the control; this guard is
      # the net under it.
      assert true
    end
  end
end
