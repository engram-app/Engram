defmodule Engram.Logger.RedactFilter do
  @moduledoc """
  Erlang `:logger` primary filter that scrubs known-sensitive keys from log
  metadata before any handler sees the event.

  Install once at boot via `:logger.add_primary_filter/2`. Scrubbed keys are
  replaced with the literal string `"[REDACTED]"` regardless of original value
  type — callers that need the raw value for debugging must not log it.

  This filter explicitly does **not** touch the message body (`event.msg`).
  Plaintext interpolated into a message string (e.g.
  `Logger.warning("failed key=\#{key}")`) leaks past this filter — call sites
  must move sensitive values into metadata, not the message string.
  """

  @redacted "[REDACTED]"

  @sensitive_keys MapSet.new([
                    # Note content
                    :content,
                    :title,
                    :tags,
                    # Paths (note + attachment + storage layer)
                    :path,
                    :source_path,
                    :note_path,
                    :file_path,
                    :attachment_path,
                    :storage_key,
                    :key,
                    # Folder structure
                    :folder,
                    :folder_name,
                    # Search
                    :query,
                    :search_query,
                    # HTTP request
                    :request_path,
                    :request_query,
                    # PII
                    :email,
                    :customer_email,
                    # Filenames
                    :attachment_name,
                    :filename,
                    :name,
                    # OAuth 2.1 — PKCE secrets (Phase 7 prep). `code_challenge`
                    # is an SHA-256 hash but it pairs with `code_verifier`,
                    # which IS the raw secret. Logging either helps an
                    # attacker replay an intercepted authorization code.
                    :code_challenge,
                    :code_verifier,
                    # OAuth tokens — never log raw bearer values
                    :access_token,
                    :refresh_token,
                    # RFC 8628 device flow — `device_code` redeems into both
                    # tokens above, so it is a bearer credential in its own
                    # right for its 300s life.
                    :device_code,
                    :authorization_header,
                    :client_secret,
                    :client_secret_hash
                  ])

  # NOTE: `:reason` is NOT in the sensitive set — many call sites use it
  # for safe atoms (`:enoent`, `:timeout`, `:no_auth`, `claim_invalid:exp`)
  # and need it to render. Anywhere that might log a Req/Postgrex error
  # struct under `:reason` should either avoid metadata or use a different
  # key. See `Engram.Telemetry.ObanDiscardHandler` for the pattern (it
  # intentionally drops `:reason` from both message body AND metadata).

  @doc """
  Returns the canonical set of metadata keys that get scrubbed.

  Exposed for tests and operator visibility — not for runtime mutation.
  """
  def sensitive_keys, do: @sensitive_keys

  @doc """
  `:logger` primary filter callback.

  Returns the event with sensitive metadata values replaced by `[REDACTED]`.

  TOP-LEVEL keys only, and ATOM keys only. `%{req: %URI{path: "/Medical/x.md"}}`
  and `%{"path" => "/Medical/x.md"}` both pass through untouched. Redacting
  nested values wholesale would destroy legitimate metadata (`counts: %{...}`),
  so the boundary is stated rather than widened: call sites must put a sensitive
  value under a sensitive key at the top level, which is what
  `Metadata.with_category/3` does.
  Never returns `:stop` or `:ignore` — this filter never drops events.
  """
  def filter(event, _opts) do
    do_filter(event)
  catch
    # A PRIMARY filter that raises — or throws, or exits — is DELETED by OTP,
    # node-wide, for the life of the VM. That would disable this entire scrub
    # (content, title, path, tokens), so the wrapper belongs around everything,
    # not around the one helper that happened to be under review.
    #
    # `redact/1` was the live route: `is_map/1` is true for a STRUCT, and
    # `Map.new(meta, ...)` raises `Protocol.UndefinedError` for any struct
    # without an `Enumerable` impl. `:logger.log(:warning, "x", %URI{})` removed
    # the filter and every subsequent path, token and note body went out in
    # clear. `%MapSet{}` does implement Enumerable, which is why a casual probe
    # misses it.
    #
    # `catch _, _` rather than `rescue`: Elixir's `rescue` only covers the
    # :error class, and OTP removes a throwing filter exactly like a raising
    # one.
    #
    # NOT PINNED, deliberately stated: with `redact/1` no longer able to raise,
    # no reachable input throws or exits here, so no test distinguishes `catch`
    # from `rescue`. It stays because the cost is one word and the failure it
    # guards against is node-wide and permanent — but a mutation swapping it
    # will not go red, and nobody should read the suite as saying otherwise.
    _, _ ->
      # M2: emit a signal. Without it a genuine redaction bug degrades every
      # line node-wide to [REDACTED] forever with nothing to notice it by.
      # Telemetry rather than Logger — logging from inside a log filter
      # re-enters this code path.
      :telemetry.execute([:engram, :logger, :redact_filter, :failed], %{count: 1}, %{})

      # M1: built rather than updated. `%{event | ...}` requires the keys to
      # exist, so an event without :msg would raise INSIDE the net and get the
      # filter deleted — precisely the outcome this exists to prevent.
      event
      |> Map.put(:meta, %{})
      |> Map.put(:msg, {:string, @redacted})
  end

  defp do_filter(%{meta: meta} = event) when is_map(meta) do
    %{event | meta: redact(meta)} |> redact_dependency_message()
  end

  defp do_filter(event), do: event

  # Dependencies log URLs that contain the storage key, and no call-site control
  # in this codebase can reach them. This filter is the only layer between them
  # and Loki.
  #
  #   ExAws.Request  "ExAws: HTTP ERROR: ... for URL: ..."   (transport errors)
  #   Req.Steps      ["redirecting to ", location]            (S3 region redirect)
  #
  # Req is the one that bites first: it follows a redirect before ExAws ever
  # sees a status, and its message is an IOLIST, not a binary.
  @url_logging_modules [ExAws.Request, Req.Steps]

  # Any scheme-bearing URL, not just the one after `for URL:`. Three shapes
  # defeated the narrower version:
  #
  #   * `Req.Steps` uses different wording entirely
  #   * ExAws's `debug_requests` line (`request.ex:33`) additionally logs
  #     `HEADERS:` and `BODY:` — for a PutObject that is the attachment bytes
  #     and a live SigV4 signature. This scrubs the URL in it and NOT those,
  #     so `debug_requests` must stay off in any environment with real data.
  #     Stated rather than implied: the previous comment named that line as if
  #     it were covered.
  #   * a non-UTF-8 key renders as `<<104, 116, ...>>`, which CONTAINS SPACES,
  #     so a `\S+` match stopped early and left the bytes behind. `/x.md` was
  #     recoverable from the decimals.
  # A scheme-bearing URL, a path-shaped run, or a byte rendering.
  #
  # The path alternative is not optional: RFC 7231 §7.1.2 permits a RELATIVE
  # `Location`, and `Req.Steps.build_redirect_request/3` logs the raw header
  # BEFORE `URI.merge` — so the very line this module was added for arrives as
  # `/bucket/u1/v1/Medical/biopsy.md`, with no scheme, and a scheme-anchored
  # pattern left it untouched. ExAws runs on Req here (config/config.exs →
  # Engram.Aws.ReqClient), so that shape is live for S3 and MinIO.
  # ANY token carrying a path separator, encoded or not, plus byte renderings.
  #
  # Enumerating shapes lost every time. A scheme anchor missed the relative
  # `Location`; adding `/\S*/\S+` still missed `Medical/biopsy.md` (no leading
  # slash), `bucket%2FMedical%2Fbiopsy.md` (percent-encoded) and `bucket/key`.
  # RFC 7231 §7.1.2 permits a relative-path reference just as much as the
  # absolute-path one, and Req logs the raw header either way.
  #
  # Only `@url_logging_modules` reaches this — two dependency log lines — so
  # over-redacting a slash-bearing token there costs almost nothing, while
  # under-redacting costs a vault path. `mfa`, level and the surrounding words
  # all survive.
  @byte_render ~r{<<[0-9, ]+>>}
  @max_scrub_bytes 32_768
  # Backslash and double-encoded forms included: the comment used to claim "any
  # separator, encoded or not" while covering only three of them. RFC 3986 also
  # permits a relative-path `Location` with NO separator at all — a bare
  # `biopsy.md` still passes, and `:filename` is in @sensitive_keys, so that
  # remains a known gap rather than a covered one.
  @separators ["/", "\\", "%2F", "%2f", "%5C", "%5c", "%25"]

  defp redact_dependency_message(%{meta: %{mfa: {mod, _, _}}, msg: {:string, msg}} = event)
       when mod in @url_logging_modules and not is_atom(msg) do
    # chardata, not a binary: `when is_binary(msg)` was a SILENT SKIP, and an
    # iolist is exactly what Req hands over.
    %{event | msg: {:string, scrub_message(msg)}}
  end

  defp redact_dependency_message(event), do: event

  # FAIL CLOSED. Belt and braces: `filter/2` also catches, so this is the
  # inner of two nets rather than the only one.
  #
  # This runs as a PRIMARY `:logger` filter, and OTP deletes a filter that
  # raises — node-wide, permanently, for the life of the VM. So one malformed
  # event would take out the entire `@sensitive_keys` scrub (content, title,
  # path, tokens), not just this rule. `IO.chardata_to_string/1` raises on an
  # atom in chardata, which `Logger.warning(:atom)` produces legally, and the
  # `msg: {:string, :atom}` shape does not even match the head above.
  #
  # An unrenderable message is replaced wholesale rather than passed through:
  # if we cannot read it we cannot prove it holds no path.
  defp scrub_message(msg) do
    msg
    |> IO.chardata_to_string()
    |> String.replace(@byte_render, @redacted)
    |> scrub_tokens()
  catch
    _, _ -> @redacted
  end

  # Per TOKEN, by substring test — linear.
  #
  # The regex it replaces was `\S*(?:/|%2F|%2f)\S*`, whose two greedy `\S*`
  # halves backtrack for the separator: quadratic on a token that has none.
  # Measured 53 ms at 1 KB, 7.1 s at 16 KB, 282 s at 100 KB — and a primary
  # filter runs in the CALLING process, so that is the caller blocked, not a
  # background cost. Same output on every case, 100 KB in under a millisecond.
  # Cost is per TOKEN, and token count is unbounded — the first perf test only
  # covered one giant token, which is the shape the OLD quadratic regex choked
  # on. Measured at 100_000 tokens: `Regex.replace` with a callback 486 ms,
  # split/map/join 196 ms, and a whole-string pre-check 0 ms when there is no
  # separator to find. All three are linear; the constants are what matter,
  # because this runs in the CALLING process.
  defp scrub_tokens(text) do
    cond do
      not String.contains?(text, @separators) ->
        # The common case: nothing to scrub, so do not walk the tokens at all.
        text

      byte_size(text) > @max_scrub_bytes ->
        # Fail closed rather than spend unbounded time in a caller's process on
        # a pathological line. Only the two dependency modules reach here, and a
        # 32 KB log line carrying paths is not a diagnostic worth preserving.
        @redacted

      true ->
        # `~r/\S+/`, not `String.split(" ")`. Splitting on a literal space drops
        # tab and newline as delimiters, so one `/` anywhere collapsed a whole
        # tab-separated dependency line to `[REDACTED]` and took its
        # diagnostics with it. The callback form is slower per token, but
        # `@max_scrub_bytes` above already bounds how many tokens can reach it.
        Regex.replace(~r/\S+/, text, &redact_token/1)
    end
  end

  defp redact_token(token) do
    if String.contains?(token, @separators), do: @redacted, else: token
  end

  # `:maps.map/2`, not `Map.new/2`.
  #
  # `Map.new/2` enumerates, and `is_map/1` is true for a STRUCT — so any struct
  # without an `Enumerable` impl raised `Protocol.UndefinedError` here and OTP
  # deleted this primary filter node-wide, taking all redaction with it. The
  # first fix guarded with `not is_struct(meta)`, which was FAIL-OPEN: struct
  # metadata then reached the handler unredacted, `%URI{path:
  # "/Medical/biopsy.md", query: "cancer prognosis"}` included.
  #
  # `:maps.map/2` works on any map including structs, so there is nothing to
  # guard against and struct metadata is redacted like everything else.
  #
  # `__struct__` is dropped first so the result is a PLAIN map. `:logger`
  # metadata is specified as one, and leaving it a struct moves the crash
  # downstream rather than removing it: `Logger.Formatter` does `Access.get/3`
  # over the metadata, and a struct implements neither Access nor Enumerable —
  # so the formatter raised instead of the filter, which is no better.
  # OTP puts these on every event itself; the formatter and handlers require
  # them. Replacing metadata wholesale removed the filter for a different reason
  # than the crash it was fixing — `Logger.Formatter` needs `:time`.
  @otp_meta_keys [
    :pid,
    :gl,
    :time,
    :mfa,
    :file,
    :line,
    :domain,
    :report_cb,
    :crash_reason,
    :initial_call,
    :registered_name,
    :ansi_color
  ]

  # A struct as metadata: keep the class and OTP's own keys, redact every field.
  #
  # Key-based redaction cannot work here — `%RuntimeError{message: ...}` has no
  # key in @sensitive_keys, and that `message` is routinely note content or a
  # path. Worse, deleting `__struct__` (which the previous version did, to stop
  # the formatter crashing) turned a term the JSON encoder REFUSED into a clean
  # encodable map, so this made the exception case strictly worse than before.
  #
  # The class name is the diagnostic an operator actually needs — `%KeyError{}`
  # vs `%Jason.EncodeError{}` — and it cannot carry user data.
  defp redact(%{__struct__: mod} = meta) do
    # NOT piped: `:maps.map/2` is (fun, map). Piping the map in gives :badarg —
    # made that mistake twice in this file, and both times the catch arm below
    # swallowed it silently and blanked every event. That is the standing cost
    # of a broad catch, and the reason the tests around it assert POSITIVE
    # values rather than only absence.
    redacted =
      :maps.map(
        fn k, v -> if k in @otp_meta_keys, do: v, else: @redacted end,
        Map.delete(meta, :__struct__)
      )

    Map.put(redacted, :meta_struct, inspect(mod))
  end

  defp redact(meta) do
    # `:maps.map/2` is (fun, map) — NOT pipeable with the map first.
    :maps.map(
      fn k, v -> if MapSet.member?(@sensitive_keys, k), do: @redacted, else: v end,
      meta
    )
  end
end
