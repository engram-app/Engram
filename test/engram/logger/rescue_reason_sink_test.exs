defmodule Engram.Logger.RescueReasonSinkTest do
  @moduledoc """
  End-to-end proof, at the SINK, that a rescued exception's reason cannot carry
  note content into Loki or CloudWatch.

  Why this exists rather than another `capture_log` assertion: `capture_log`
  renders the DEV text formatter, whose `metadata:` allowlist in
  config/config.exs does not contain `:error`. A leak in `error:` metadata is
  therefore INVISIBLE to capture_log and fully visible in prod — a test that
  passes for a reason that does not hold in production.

  Prod uses `{LoggerJSON.Formatters.Basic, metadata: {:all_except, [...]}}`
  (config/prod.exs) — an emit-everything-but-a-few-keys list. So this builds the
  real event, runs the real `RedactFilter`, and formats with the real prod
  formatter config.
  """
  use ExUnit.Case, async: true

  alias Engram.Logger.Metadata
  alias Engram.Logger.RedactFilter

  @secret "Dear diary, the biopsy came back positive."

  defp prod_line(meta, message) do
    event = %{level: :error, msg: {:string, message}, meta: meta}
    filtered = RedactFilter.filter(event, [])

    {mod, cfg} = LoggerJSON.Formatters.Basic.new(metadata: {:all_except, [:__sentry__]})

    mod.format(filtered, cfg) |> IO.iodata_to_binary() |> String.trim() |> Jason.decode!()
  end

  test "the reason a rescue logs never reaches the prod sink with note content" do
    e = %CaseClauseError{term: {:parsed, @secret}}
    reason = Metadata.safe_reason(e)

    meta =
      Metadata.with_category(:error, :sync, path: "Medical/biopsy.md", error: reason)
      |> Map.new()

    decoded = prod_line(meta, "batch entry raised, degrading note path_hmac=abc (#{reason})")
    line = Jason.encode!(decoded)

    refute line =~ "biopsy"
    refute line =~ @secret
    # The class survives, so the line still says what broke.
    assert decoded["metadata"]["error"] == "CaseClauseError"
    # And the path is redacted by key, as it already was.
    assert decoded["metadata"]["path"] == "[REDACTED]"
  end

  # The failing half, stated as a test so the reason for safe_reason/1 is not
  # re-derived: RedactFilter has no `:error` key, so putting a raw message there
  # is NOT gated. This asserts the property that made the earlier fix wrong.
  test "RedactFilter does not gate the :error key, which is why the type filter exists" do
    meta =
      Metadata.with_category(:error, :sync,
        error: Exception.message(%CaseClauseError{term: @secret})
      )
      |> Map.new()

    line = prod_line(meta, "batch entry raised") |> Jason.encode!()

    assert line =~ "biopsy",
           "RedactFilter now scrubs :error — safe_reason/1 may be redundant, re-check it"
  end

  # The storage key IS a vault path — `user/vault/Medical/biopsy.md`. It is in
  # RedactFilter's `@sensitive_keys`, so `storage_key:` metadata comes out
  # `[REDACTED]`. But the SAME key rides inside the ExAws error term, and
  # `:reason` is not a sensitive key — so the control was defeated by the value
  # simply travelling under a different name in the same log call.
  #
  # This is what a key-based redactor cannot do on its own, and why the reason
  # has to be rendered rather than trusted.
  test "a storage key redacted by name does not leak inside :reason" do
    key = "u1/v1/Medical/biopsy.md"

    # The shape ExAws hands back for a 4xx: the whole response map.
    {:error, reason} =
      ExAws.Request.client_error(
        %{
          status_code: 404,
          body: "<Error><Code>NoSuchKey</Code><Key>#{key}</Key></Error>",
          headers: []
        },
        Jason
      )

    # The premise: rendering it raw discloses the path the sibling key hides.
    assert inspect(reason) =~ "Medical"

    meta =
      Metadata.with_category(:error, :sync,
        storage_key: key,
        reason: Metadata.safe_reason(reason)
      )
      |> Map.new()

    line = prod_line(meta, "S3.exists? failed")
    encoded = Jason.encode!(line)

    assert encoded =~ "[REDACTED]", "storage_key should still be redacted by name"
    refute encoded =~ "Medical"
    refute encoded =~ "biopsy"
    # The diagnostic survives: an operator still learns WHICH S3 error it was.
    assert encoded =~ "NoSuchKey"
  end

  # ExAws logs the object URL itself, from inside the dependency. No call-site
  # control reaches it: `ExAws.Request.Url.sanitize/2` only URI-encodes the
  # path, so the storage key survives, and prod runs at `:info` so it shipped on
  # every transport error. The message BODY is also the half RedactFilter's
  # key-based pass explicitly does not touch — this is the one seam that can.
  test "the ExAws URL log cannot carry a vault path to the sink" do
    url = "https://bucket.s3.example.com/u1/v1/Medical/biopsy.md"

    msg =
      "ExAws: HTTP ERROR: #{inspect(:timeout)} for URL: #{inspect(url)} ATTEMPT: 3"

    # The premise: unfiltered, this is a vault path in a prod log line.
    assert msg =~ "Medical"

    event = %{
      level: :warning,
      msg: {:string, msg},
      meta: %{mfa: {ExAws.Request, :request_and_retry, 7}}
    }

    filtered = RedactFilter.filter(event, [])
    {:string, out} = filtered.msg

    refute out =~ "Medical"
    refute out =~ "biopsy"
    # The diagnostic survives — which error, and which attempt.
    assert out =~ "timeout"
    assert out =~ "ATTEMPT: 3"
  end

  # Req follows an S3 region redirect BEFORE ExAws sees a status, and hands the
  # message over as an IOLIST. The previous `when is_binary(msg)` guard made
  # that a silent skip — the filter simply did not run.
  test "a Req redirect iolist is scrubbed" do
    url = "https://bucket.s3.us-west-2.amazonaws.com/u1/v1/Medical/biopsy.md"

    event = %{
      level: :debug,
      msg: {:string, ["redirecting to ", url]},
      meta: %{mfa: {Req.Steps, :redirect, 1}}
    }

    {:string, out} = RedactFilter.filter(event, []).msg

    refute out =~ "Medical"
    assert out =~ "redirecting to"
  end

  # A non-UTF-8 key renders as `<<104, 116, ...>>`, which contains SPACES — so
  # a `\S+` match stopped at the first one and left the bytes in the line. The
  # decimals are trivially reversible.
  test "a byte-rendered key does not survive" do
    msg =
      "ExAws: HTTP ERROR: :timeout for URL: " <>
        inspect(<<104, 116, 116, 112, 58, 47, 47, 120, 47, 255, 46, 109, 100>>) <> " ATTEMPT: 3"

    event = %{level: :warning, msg: {:string, msg}, meta: %{mfa: {ExAws.Request, :r, 7}}}
    {:string, out} = RedactFilter.filter(event, []).msg

    refute out =~ "109, 100"
    assert out =~ "ATTEMPT: 3"
  end

  # Our own log lines must not be touched by that rule.
  test "a non-ExAws message with the same words is left alone" do
    msg = "sync failed for URL: internal"
    event = %{level: :warning, msg: {:string, msg}, meta: %{}}

    assert RedactFilter.filter(event, []).msg == {:string, msg}
  end
end
