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

  test "diagnostic entries get loki_ship: true even at info level" do
    user = insert(:user)
    parent = self()
    ref = make_ref()
    handler_id = :logs_reemit_test_handler

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    :logger.add_handler(handler_id, __MODULE__, %{config: %{parent: parent, ref: ref}})
    on_exit(fn -> :logger.remove_handler(handler_id) end)

    {:ok, 1} =
      Logs.insert_logs(user, [
        %{
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "level" => "info",
          "category" => "vault",
          "message" => "modify path=a.md",
          "diagnostic" => true,
          "conn_id" => "c1"
        }
      ])

    assert_receive {^ref, _level, meta}, 1000
    assert meta[:loki_ship] == true
    assert meta[:category] == :client
  end

  test "client-originated 'error' severity is capped at :warning so it never inflates the backend error-rate alert, but the original severity survives in metadata" do
    user = insert(:user)
    parent = self()
    ref = make_ref()
    handler_id = :logs_reemit_severity_test_handler

    :logger.add_handler(handler_id, __MODULE__, %{config: %{parent: parent, ref: ref}})
    on_exit(fn -> :logger.remove_handler(handler_id) end)

    {:ok, 1} =
      Logs.insert_logs(user, [
        %{
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "level" => "error",
          "category" => "channel",
          "message" => "rate_limited",
          "conn_id" => "c2",
          "device_id" => "d1"
        }
      ])

    assert_receive {^ref, level, meta}, 1000
    assert level == :warning
    assert meta[:category] == :client
    assert meta[:client_severity] == "error"
  end

  # :logger handler callback
  def log(%{level: level, meta: meta}, %{config: %{parent: parent, ref: ref}}) do
    if meta[:category] == :client and meta[:conn_id] in ["c1", "c2"] do
      send(parent, {ref, level, meta})
    end

    :ok
  end
end
