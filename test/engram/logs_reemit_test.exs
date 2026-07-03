defmodule Engram.LogsReemitTest do
  use Engram.DataCase, async: false
  import ExUnit.CaptureLog
  alias Engram.Logs

  test "re-emits client logs through Logger with conn_id metadata" do
    user = insert(:user)

    log =
      capture_log(fn ->
        {:ok, 1} =
          Logs.insert_logs(user, [
            %{
              "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "level" => "warn",
              "category" => "channel",
              "message" => "WS closed before open",
              "conn_id" => "c1",
              "device_id" => "d1"
            }
          ])
      end)

    assert log =~ "WS closed before open"
    assert log =~ "c1"
  end
end
