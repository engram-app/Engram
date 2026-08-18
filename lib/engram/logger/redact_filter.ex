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
                    :client_secret_hash,
                    # Only reachable with a NON-atom value: a real struct is
                    # handled by `redact/1`'s first clause, which keeps the class
                    # as `meta_struct`. Anything else carrying this key is a term
                    # of unknown shape, and letting it through would just move
                    # the leak the `is_atom/1` guard was added to close.
                    :__struct__
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

  # The message from these two modules is DROPPED, not scrubbed.
  #
  # Four scrub rules have now shipped for this seam and every one of them
  # leaked. Per-token lost the suffix of a path containing a space. Per-element
  # lost the tail of a path split across elements, and REGRESSED a case the
  # token rule had clean. Per-quoted-span disagreed with the separator list on
  # the percent-encoded forms. Prefix-truncation — the last one — kept the text
  # BEFORE the first token holding a separator, which leaks the folder name
  # itself the moment it contains a space:
  #
  #     ["redirecting to ", "Medical Records/2026/biopsy.md"]
  #       -> "redirecting to Medical [REDACTED]"
  #
  # A folder named `Medical Records` or `Divorce 2026` discloses the sensitive
  # fact on its own. That one is not a near-miss, it is the whole harm.
  #
  # The pattern, once four data points make it visible: every rule tried to keep
  # SOME of a string we do not author, and each needed a boundary — where the
  # path starts, where it ends — that nothing in the text actually marks. There
  # is always another shape, and it is by definition the one nobody thought of.
  # Two more leaked past prefix-truncation without needing a new rule at all: a
  # filename with no separator (`biopsy.md`), and `inspect/1` truncating a
  # non-UTF-8 key at 100 bytes so the byte-render regex no longer matched and
  # the path shipped as recoverable decimals.
  #
  # So: keep nothing. We cannot prove any part of a third party's message is
  # safe, and the requirement is absolute. This cannot be defeated by a space, a
  # quote, an encoding, an element boundary, a truncation or a shape nobody has
  # seen, because it does not read the message.
  #
  # WHAT SURVIVES, and why this is not a real diagnostic loss: `meta` is ours
  # and is untouched here — `mfa` names the module and function, and the level
  # is intact. The error KIND is not lost either, because our own call sites log
  # it safely: `storage/s3.ex` records `reason: safe_reason(reason)`, which
  # renders `http_error 403 AccessDenied`. The dependency line was always
  # supplementary to that. What actually goes is `ATTEMPT: 3` and the ExAws
  # `debug_requests` dump — and that dump carried a live SigV4 signature and
  # attachment bytes, so losing it is a second win rather than a cost.
  #
  # No message shape is read, so nothing here can raise. That also closes a gap
  # the previous version had: it matched only `{:string, chardata}`, so an
  # Erlang-style `{format, args}` or `{:report, _}` from one of these modules
  # skipped the scrub entirely. Every shape is now covered.
  defp redact_dependency_message(%{meta: %{mfa: {mod, _, _}}} = event)
       when mod in @url_logging_modules do
    %{event | msg: {:string, @redacted}}
  end

  defp redact_dependency_message(event), do: event

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
  #
  # `is_atom(mod)`: a real struct's `__struct__` is always a module, but this
  # head matches any map carrying that KEY, and `inspect/1` on the value was
  # unbounded. `%{__struct__: %{note: "<body>"}}` rendered the whole term into
  # `meta_struct` — a redactor emitting a term rather than a label, which is the
  # exact defect this PR's call-site guard exists to catch. A non-atom falls
  # through to the plain clause below, where `__struct__` is not a sanctioned
  # key and so is redacted like any other unknown value.
  defp redact(%{__struct__: mod} = meta) when is_atom(mod) do
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
