defmodule Engram.LogsTest do
  use Engram.DataCase, async: true
  alias Engram.Logs

  test "insert_logs persists conn_id and device_id" do
    user = insert(:user)

    {:ok, 1} =
      Logs.insert_logs(user, [
        %{
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "level" => "info",
          "category" => "channel",
          "message" => "opened",
          "conn_id" => "c1",
          "device_id" => "d1"
        }
      ])

    {:ok, [row]} = Logs.list_logs(user, [])
    assert row.conn_id == "c1"
    assert row.device_id == "d1"
  end

  describe "forced provenance" do
    # `forced` records that an entry bypassed the CLIENT's diagnostics gate.
    # The plugin's RemoteLogger.anomaly/3 ships with force: true on purpose, so
    # a fresh install with telemetry OFF still reports a silent first-sync
    # failure (prod 2026-08-13: 316 of 316 notes dropped, nothing to read).
    #
    # It has to be PERSISTED, not merely used for routing like `diagnostic`.
    # Once stored, a forced anomaly is otherwise byte-identical to an ordinary
    # warn — so nothing can tell a signal covering the WHOLE fleet from one
    # covering only opted-in users, and the e2e asserting "disabling stops the
    # flush" cannot exempt the one class contractually allowed through
    # (engram-app/Engram#1598).
    test "persists forced and returns it from list_logs" do
      user = insert(:user)

      assert {:ok, 1} =
               Logs.insert_logs(user, [
                 %{
                   "level" => "warn",
                   "category" => "sync",
                   "message" => "replay_produced_no_files applied=1 files=0",
                   "forced" => true
                 }
               ])

      assert {:ok, [entry]} = Logs.list_logs(user, [])
      assert entry.forced == true
    end

    # Provenance, not severity: an ordinary warn from an opted-in client must
    # not claim the exemption, or the flag stops answering its question.
    test "an entry without the flag is not forced" do
      user = insert(:user)

      assert {:ok, 1} =
               Logs.insert_logs(user, [
                 %{"level" => "warn", "category" => "sync", "message" => "ordinary warning"}
               ])

      assert {:ok, [entry]} = Logs.list_logs(user, [])
      refute entry.forced
    end
  end
end
