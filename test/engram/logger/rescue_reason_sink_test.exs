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

  # RFC 7231 §7.1.2 permits a RELATIVE Location, and Req logs the raw header
  # before `URI.merge` — so the very shape this filter was added for arrives
  # with no scheme, and a scheme-anchored pattern left it untouched.
  test "a relative Location redirect is scrubbed" do
    event = %{
      level: :debug,
      msg: {:string, ["redirecting to ", "/bucket/u1/v1/Medical/biopsy.md"]},
      meta: %{mfa: {Req.Steps, :redirect, 1}}
    }

    {:string, out} = RedactFilter.filter(event, []).msg

    refute out =~ "Medical"
    assert out =~ "redirecting to"
  end

  # THE most important test in this file.
  #
  # This is a PRIMARY `:logger` filter, and OTP deletes a filter that raises —
  # node-wide, permanently. So one malformed event would disable the entire
  # @sensitive_keys scrub (content, title, path, tokens) for the life of the
  # VM. `IO.chardata_to_string/1` raises on an atom in chardata, which
  # `Logger.warning(:atom)` produces legally.
  test "a message the filter cannot render does not raise, and fails closed" do
    for msg <- [
          ["redirecting to ", :some_atom],
          [<<0xFF>>, "bad utf8"],
          [1_114_112]
        ] do
      event = %{level: :warning, msg: {:string, msg}, meta: %{mfa: {Req.Steps, :r, 1}}}

      assert %{msg: {:string, out}} = RedactFilter.filter(event, [])
      assert out == "[REDACTED]", "unrenderable message must fail closed, got #{inspect(out)}"
    end
  end

  # `msg: {:string, :atom}` does not match the scrub head at all — it must fall
  # through the catch-all rather than raise a FunctionClauseError.
  test "an atom message falls through untouched" do
    event = %{level: :warning, msg: {:string, :shutdown}, meta: %{mfa: {Req.Steps, :r, 1}}}

    assert RedactFilter.filter(event, []).msg == {:string, :shutdown}
  end

  # Our own log lines must not be touched by that rule.
  test "a non-ExAws message with the same words is left alone" do
    msg = "sync failed for URL: internal"
    event = %{level: :warning, msg: {:string, msg}, meta: %{}}

    assert RedactFilter.filter(event, []).msg == {:string, msg}
  end

  # THE filter must survive, and must keep redacting.
  #
  # Everything else in this file tests `filter/2` by calling it directly, which
  # cannot observe the failure that matters: OTP DELETES a primary filter that
  # raises, throws or exits — node-wide, for the life of the VM — and every
  # later path, token and note body then ships in clear. Six review rounds ran
  # with that route unpinned, and reverting the fix left the suite green.
  #
  # These install the real filter and drive the real `:logger` API.
  describe "the primary filter survives everything :logger can hand it" do
    setup do
      :logger.add_primary_filter(:engram_redact_test, {&RedactFilter.filter/2, []})
      on_exit(fn -> :logger.remove_primary_filter(:engram_redact_test) end)
      :ok
    end

    defp installed?, do: :engram_redact_test in Keyword.keys(:logger.get_primary_config().filters)

    test "a struct metadata does not remove the filter" do
      assert installed?()

      # `is_map/1` is true for a struct, and `Map.new/2` raises
      # Protocol.UndefinedError on one with no Enumerable impl. %MapSet{} HAS
      # one, which is why a casual probe misses this.
      for meta <- [%URI{}, %RuntimeError{message: "x"}] do
        try do
          :logger.log(:warning, "probe", meta)
        catch
          _, _ -> :ok
        end
      end

      assert installed?(), "the primary filter was removed — all redaction is now off"
    end

    # Struct metadata must be REDACTED, not merely survived. The first fix
    # guarded with `not is_struct(meta)`, which passed it through in clear.
    test "struct metadata is redacted, not waved through" do
      out =
        RedactFilter.filter(
          %{
            level: :warning,
            msg: {:string, "m"},
            meta: %URI{path: "/Medical/biopsy.md", query: "cancer prognosis"}
          },
          []
        )

      refute inspect(out.meta) =~ "Medical"
      refute inspect(out.meta) =~ "cancer"
    end

    # `rescue` covers only the :error class; OTP removes a THROWING filter
    # exactly like a raising one.
    test "every exit class leaves the filter installed and redacting" do
      for meta <- [%URI{}, :not_a_map, %{msg_only: 1}] do
        try do
          :logger.log(:error, "probe", meta)
        catch
          _, _ -> :ok
        end
      end

      assert installed?()

      ev = %{level: :error, msg: {:string, "m"}, meta: %{path: "Medical/x.md"}}
      assert RedactFilter.filter(ev, []).meta.path == "[REDACTED]"
    end
  end

  # The shapes the widening was made for. Each was leaking under the previous
  # pattern, and none of them was covered — all three reverts stayed green.
  describe "separator-bearing tokens in dependency lines" do
    for {name, raw} <- [
          {"a relative path with no leading slash", "Medical/biopsy.md"},
          {"a percent-encoded key", "bucket%2FMedical%2Fbiopsy.md"},
          {"a bare bucket/key", "bucket/Medical.md"}
        ] do
      test "#{name} is redacted" do
        raw = unquote(raw)

        event = %{
          level: :debug,
          msg: {:string, ["redirecting to ", raw]},
          meta: %{mfa: {Req.Steps, :r, 1}}
        }

        {:string, out} = RedactFilter.filter(event, []).msg

        refute out =~ "Medical", "leaked: #{out}"
        assert out =~ "redirecting to"
      end
    end
  end

  # I1: the previous pattern was quadratic and ran in the CALLING process —
  # 7.1 s at 16 KB, 282 s at 100 KB.
  test "a large separator-free message cannot block the caller" do
    msg = String.duplicate("a", 100_000)
    event = %{level: :warning, msg: {:string, msg}, meta: %{mfa: {ExAws.Request, :r, 7}}}

    started = System.monotonic_time(:millisecond)
    RedactFilter.filter(event, [])

    assert System.monotonic_time(:millisecond) - started < 500
  end
end
