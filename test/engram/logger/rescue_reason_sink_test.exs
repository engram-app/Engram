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

    # What survives is the PREFIX: an operator still learns this was an ExAws
    # timeout. `ATTEMPT: 3` does not survive, because ExAws puts it AFTER the
    # URL and nothing in the line marks where the path ends — see
    # `truncate_at_separator/1`. Pinned as an equality so the trade is visible
    # here rather than implied: if a future change claims to keep the tail, this
    # test says exactly what it would be keeping it past.
    assert out == "ExAws: HTTP ERROR: :timeout for URL: [REDACTED]"
    assert out =~ "timeout"
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

    # `@otp_meta_keys` is load-bearing and was shipping unpinned: deleting the
    # whole list left the suite green.
    #
    # OTP merges its own keys INTO struct-shaped metadata, so a struct event
    # arrives carrying `:pid`, `:time` and `:gl` alongside the struct's fields.
    # The formatter requires them — replacing metadata wholesale removed the
    # filter for a different reason than the crash it was fixing.
    #
    # Reachability note: `Logger.error("m", %URI{})` raises at the CALL SITE
    # (the macro cannot take a struct), so only the raw `:logger.log/3` OTP API
    # reaches the struct clause at all.
    test "OTP's own metadata keys survive struct redaction" do
      out =
        RedactFilter.filter(
          %{
            level: :error,
            msg: {:string, "m"},
            meta:
              Map.merge(
                %{pid: self(), time: 123, gl: self()},
                Map.from_struct(%URI{path: "/Medical/x.md"})
              )
              |> Map.put(:__struct__, URI)
          },
          []
        )

      # The struct's own fields are redacted...
      assert out.meta.path == "[REDACTED]"
      assert out.meta.meta_struct == "URI"
      # ...and OTP's are not, or the formatter breaks downstream.
      assert out.meta.time == 123
      assert out.meta.pid == self()
      assert out.meta.gl == self()
    end

    # `meta_struct` was `inspect(mod)` with no guard and no bound, and this head
    # matches any map carrying the KEY — not only a real struct. So a non-atom
    # value was rendered into the log verbatim: a redactor emitting a term
    # rather than a label, which is the defect the call-site guard in
    # log_call_compliance_test.exs exists to catch.
    test "a non-atom __struct__ is redacted, not inspected into the line" do
      out =
        RedactFilter.filter(
          %{
            level: :error,
            msg: {:string, "m"},
            meta: %{__struct__: %{note: "Dear diary, the biopsy came back positive"}, time: 1}
          },
          []
        )

      refute inspect(out.meta) =~ "biopsy"
      assert out.meta.__struct__ == "[REDACTED]"
      # Not the struct path: there is no class to report, so no label is minted.
      refute Map.has_key?(out.meta, :meta_struct)
    end

    # Struct metadata must be REDACTED, not merely survived. The first fix
    # guarded with `not is_struct(meta)`, which passed it through in clear.
    # POSITIVE assertions, deliberately.
    #
    # The previous version was all `refute`, and the catch arm sets
    # `meta: %{}` — so "redacted correctly" and "wiped by the fail-closed net"
    # were indistinguishable to it. Reverting `redact/1` to the raising version
    # left the ENTIRE 4589-test suite green: the net that makes the bug
    # survivable is the same net that made it untestable.
    test "an exception struct keeps its class and loses every field" do
      secret = "Dear diary, the biopsy came back positive"

      out =
        RedactFilter.filter(
          %{level: :warning, msg: {:string, "m"}, meta: %RuntimeError{message: secret}},
          []
        )

      # The leak this closes: deleting `__struct__` turned a term the JSON
      # encoder REFUSED into a clean encodable map carrying `message`.
      refute inspect(out.meta) =~ "biopsy"
      # Positive: CLASSIFIED and field-redacted, not blanked by the catch arm.
      assert out.meta.meta_struct == "RuntimeError"
      assert out.meta.message == "[REDACTED]"
      assert out.msg == {:string, "m"}
    end

    test "a plain map keeps its non-sensitive keys" do
      out =
        RedactFilter.filter(
          %{
            level: :warning,
            msg: {:string, "m"},
            meta: %{path: "/Medical/biopsy.md", vault_id: "v-1", note_id: "n-1"}
          },
          []
        )

      assert out.meta.path == "[REDACTED]"
      # The half that distinguishes real redaction from the catch arm wiping
      # metadata wholesale.
      assert out.meta.vault_id == "v-1"
      assert out.meta.note_id == "n-1"
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

      ev = %{level: :error, msg: {:string, "m"}, meta: %{path: "Medical/x.md", vault_id: "v-1"}}
      out = RedactFilter.filter(ev, [])

      assert out.meta.path == "[REDACTED]"
      # Positive half: proves redaction still RUNS, rather than the catch arm
      # having quietly taken over for every event from here on.
      assert out.meta.vault_id == "v-1"
    end
  end

  # The shapes the widening was made for. Each was leaking under the previous
  # pattern, and none of them was covered — all three reverts stayed green.
  describe "separator-bearing tokens in dependency lines" do
    for {name, raw} <- [
          {"a relative path with no leading slash", "Medical/biopsy.md"},
          {"a percent-encoded key", "bucket%2FMedical%2Fbiopsy.md"},
          {"a bare bucket/key", "bucket/Medical.md"},
          # Added in response to review, and shipped with nothing holding them:
          # reverting @separators to its original three entries left the suite
          # green.
          {"a backslash-separated path", "Medical\\biopsy.md"},
          {"a percent-encoded backslash", "Medical%5Cbiopsy.md"},
          {"a double-encoded separator", "Medical%252Fbiopsy.md"}
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

  # The other axis: many small tokens that DO carry separators, so the walk is
  # actually entered. The first version of this test used separator-free
  # tokens, which the whole-string pre-check short-circuits — it never reached
  # the code it claimed to measure and merely duplicated the test below.
  # Sized just under @max_scrub_bytes so the cap does not short-circuit it
  # either.
  test "a separator-dense message under the cap cannot block the caller" do
    msg = String.duplicate("a/b ", 8_000)
    event = %{level: :warning, msg: {:string, msg}, meta: %{mfa: {ExAws.Request, :r, 7}}}

    started = System.monotonic_time(:millisecond)
    RedactFilter.filter(event, [])

    assert System.monotonic_time(:millisecond) - started < 500
  end

  # Tab and newline are delimiters, not ordinary characters.
  #
  # If they were not, the whole line would be ONE token, the prefix would be
  # empty, and the result would be a bare `[REDACTED]` — so the surviving `tab`
  # is what proves the split. The trailing `kept` does NOT survive, and that is
  # the deliberate trade in `truncate_at_separator/1`: nothing marks where a
  # path ends, so everything past the first separator goes. An earlier version
  # kept it by scrubbing per token, and shipped `biopsy` and `results.md` in
  # clear for any path containing a space.
  test "tab is a delimiter, so the prefix survives and the tail does not" do
    event = %{
      level: :warning,
      msg: {:string, "tab\tMedical/biopsy.md\tkept"},
      meta: %{mfa: {ExAws.Request, :r, 7}}
    }

    {:string, out} = RedactFilter.filter(event, []).msg

    assert out == "tab\t[REDACTED]"
    refute out =~ "Medical"
    refute out =~ "kept"
  end

  # Pins the whole-string pre-check. Without it every token is walked even when
  # there is no separator anywhere — the overwhelmingly common case for a
  # dependency log line.
  test "a large separator-free message skips the token walk entirely" do
    msg = String.duplicate("ab ", 400_000)
    event = %{level: :warning, msg: {:string, msg}, meta: %{mfa: {ExAws.Request, :r, 7}}}

    started = System.monotonic_time(:millisecond)
    assert %{msg: {:string, ^msg}} = RedactFilter.filter(event, [])

    assert System.monotonic_time(:millisecond) - started < 200
  end

  # Pins the size cap: past it, fail closed rather than spend unbounded time in
  # a caller's process. Only two dependency modules reach this rule.
  test "a pathological separator-bearing message is capped, not walked" do
    msg = String.duplicate("a/b ", 20_000)
    assert byte_size(msg) > 32_768
    event = %{level: :warning, msg: {:string, msg}, meta: %{mfa: {ExAws.Request, :r, 7}}}

    started = System.monotonic_time(:millisecond)
    {:string, out} = RedactFilter.filter(event, []).msg

    assert out == "[REDACTED]"
    assert System.monotonic_time(:millisecond) - started < 200
  end

  # The limits the moduledoc names, asserted as CURRENT BEHAVIOUR.
  #
  # These are gaps, not features. They are pinned so that closing one is a
  # deliberate act with a red test attached, and so nobody reads the moduledoc's
  # honesty as hedging — every leak in this series survived behind a comment
  # claiming more coverage than the code had.
  describe "known gaps (pinned so a change is noticed)" do
    test "nested metadata is NOT redacted" do
      out =
        RedactFilter.filter(
          %{level: :warning, msg: {:string, "m"}, meta: %{req: %{path: "/Medical/biopsy.md"}}},
          []
        )

      assert out.meta.req.path == "/Medical/biopsy.md",
             "nesting is now redacted — good, update the moduledoc and delete this"
    end

    test "non-atom metadata keys are NOT redacted" do
      out =
        RedactFilter.filter(
          %{level: :warning, msg: {:string, "m"}, meta: %{"path" => "/Medical/biopsy.md"}},
          []
        )

      assert out.meta["path"] == "/Medical/biopsy.md",
             "string keys are now redacted — good, update the moduledoc and delete this"
    end

    # A dependency line with a separator-free filename. `:filename` is itself a
    # sensitive key, so this is a real gap in the message scrub.
    test "a separator-free filename in a dependency line is NOT scrubbed" do
      event = %{
        level: :debug,
        msg: {:string, ["redirecting to ", "biopsy.md"]},
        meta: %{mfa: {Req.Steps, :r, 1}}
      }

      {:string, out} = RedactFilter.filter(event, []).msg

      assert out =~ "biopsy.md",
             "separator-free tokens are now scrubbed — update the moduledoc and delete this"
    end
  end
end
