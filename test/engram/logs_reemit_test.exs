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
    # The STRING is what Fluent Bit routes on; the boolean alone shipped
    # nothing for months (engram-app/engram-infra#1095).
    assert meta[:ship] == "loki"
    assert meta[:category] == :client
  end

  # `diagnostic` is a client-controlled boolean off the request body. Before the
  # paired routing rule existed it was a flag nothing read, so an unbounded
  # batch was absorbed silently; it is a live Loki-ingest lever now. Entries
  # past the cap still reach CloudWatch and the DB — only the Loki copy drops.
  test "only the first @max_diagnostic_ships entries of a batch force a Loki ship" do
    user = insert(:user)
    parent = self()
    ref = make_ref()
    handler_id = :logs_reemit_cap_handler

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    :logger.add_handler(handler_id, __MODULE__, %{config: %{parent: parent, ref: ref}})
    on_exit(fn -> :logger.remove_handler(handler_id) end)

    entries =
      for i <- 1..120 do
        %{
          "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "level" => "info",
          "category" => "vault",
          "message" => "modify #{i}",
          "diagnostic" => true,
          # The shared handler below only forwards entries with this conn_id.
          "conn_id" => "c1"
        }
      end

    {:ok, 120} = Logs.insert_logs(user, entries)

    shipped =
      Enum.reduce(1..121, 0, fn _, acc ->
        receive do
          {^ref, _level, meta} -> if meta[:ship] == "loki", do: acc + 1, else: acc
        after
          200 -> acc
        end
      end)

    assert shipped == 100
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
