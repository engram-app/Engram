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
end
