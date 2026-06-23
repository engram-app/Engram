defmodule Engram.Logger.DecryptFailureTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Engram.Logger.DecryptFailure
  alias Engram.Test.LogCapture

  # A reason term that wraps a secret. Decrypt failures bubble up Req/Postgrex/
  # crypto error terms that can carry tokens, passwords, or bound params. The
  # raw reason must NEVER reach the log — only a bounded error_kind atom.
  @secret "VOYAGE-BEARER-SENTINEL-do-not-leak"

  describe "log/3" do
    test "puts identifiers in metadata so operators can filter an incident" do
      log =
        capture_log(fn ->
          DecryptFailure.log("decrypt_failed", :aad_mismatch, user_id: "u-123", note_id: "n-456")
        end)

      assert log =~ "decrypt_failed"
      assert log =~ "user_id=u-123"
      assert log =~ "note_id=n-456"
    end

    test "renders a bounded error_kind atom, not the raw reason" do
      log =
        capture_log(fn ->
          DecryptFailure.log("decrypt_failed", {:badmatch, @secret}, user_id: "u-123")
        end)

      assert log =~ "error_kind=badmatch"
    end

    test "never leaks a secret carried in a tuple reason" do
      log =
        capture_log(fn ->
          DecryptFailure.log("decrypt_failed", {:badmatch, @secret}, user_id: "u-123")
        end)

      refute log =~ @secret
    end

    test "never leaks a secret carried in an exception reason" do
      reason = %RuntimeError{message: @secret}

      log =
        capture_log(fn ->
          DecryptFailure.log("decrypt_failed", reason, user_id: "u-123")
        end)

      assert log =~ "error_kind=RuntimeError"
      refute log =~ @secret
    end

    test "logs at :error level" do
      log =
        capture_log(fn ->
          DecryptFailure.log("decrypt_failed", :no_dek, user_id: "u-123")
        end)

      assert log =~ "[error]"
    end

    test "stamps category: :crypto and loki_ship: true so the line routes to Loki" do
      {_result, events} =
        LogCapture.with_events(fn ->
          DecryptFailure.log("decrypt_failed", :no_dek, user_id: "u-123")
        end)

      event = Enum.find(events, &(&1.level == :error))

      assert event, "expected an :error-level decrypt-failure event"
      assert event.meta.category == :crypto
      assert event.meta.loki_ship == true
      # The pre-existing bounded error_kind behavior is preserved.
      assert event.meta.error_kind == :no_dek
    end
  end
end
