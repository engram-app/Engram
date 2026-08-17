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
    _, _ -> %{event | meta: %{}, msg: {:string, @redacted}}
  end

  # Structs are excluded explicitly as well as caught, so the ordinary path
  # stays exact rather than relying on the net above.
  defp do_filter(%{meta: meta} = event) when is_map(meta) and not is_struct(meta) do
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
  @url_pattern ~r{\S*(?:/|%2F|%2f)\S*|<<[0-9, ]+>>}

  defp redact_dependency_message(%{meta: %{mfa: {mod, _, _}}, msg: {:string, msg}} = event)
       when mod in @url_logging_modules and not is_atom(msg) do
    # chardata, not a binary: `when is_binary(msg)` was a SILENT SKIP, and an
    # iolist is exactly what Req hands over.
    %{event | msg: {:string, scrub_message(msg)}}
  end

  defp redact_dependency_message(event), do: event

  # FAIL CLOSED, and never raise.
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
    |> String.replace(@url_pattern, @redacted)
  catch
    _, _ -> @redacted
  end

  defp redact(meta) do
    Map.new(meta, fn {k, v} ->
      if MapSet.member?(@sensitive_keys, k), do: {k, @redacted}, else: {k, v}
    end)
  end
end
