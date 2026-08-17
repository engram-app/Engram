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
  def filter(%{meta: meta} = event, _opts) when is_map(meta) do
    %{event | meta: redact(meta)} |> redact_dependency_message()
  end

  def filter(event, _opts), do: event

  # ExAws logs the object URL itself, and no call-site control can reach it:
  #
  #     Logger.warning("ExAws: HTTP ERROR: \#{inspect(reason)} for URL: " <>
  #                    "\#{inspect(safe_url)} ATTEMPT: \#{attempt}")
  #
  # `ExAws.Request.Url.sanitize/2` only URI-ENCODES the path, so the storage key
  # — `u1/v1/Medical/biopsy.md`, a vault path — survives verbatim. Prod runs at
  # `:info`, so this shipped on every transport error: exactly the MinIO and
  # Tigris flakes this system actually has.
  #
  # It is a dependency's MESSAGE BODY, so neither the key-based redaction above
  # nor the source guard over our own call sites can see it. This filter is the
  # only layer that sits between it and Loki.
  #
  # The URL is replaced rather than the event dropped: the reason and the
  # attempt number are the diagnostic, and losing "S3 timed out on attempt 3"
  # to hide a path we can already identify by other means is a bad trade.
  defp redact_dependency_message(
         %{meta: %{mfa: {ExAws.Request, _, _}}, msg: {:string, msg}} = event
       )
       when is_binary(msg) do
    %{event | msg: {:string, String.replace(msg, ~r/for URL: \S+/, "for URL: #{@redacted}")}}
  end

  defp redact_dependency_message(event), do: event

  defp redact(meta) do
    Map.new(meta, fn {k, v} ->
      if MapSet.member?(@sensitive_keys, k), do: {k, @redacted}, else: {k, v}
    end)
  end
end
