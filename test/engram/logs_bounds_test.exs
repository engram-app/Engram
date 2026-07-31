defmodule Engram.LogsBoundsTest do
  @moduledoc """
  Write-path bounds for `POST /api/logs` (#1135).

  Before this, the only ceiling on the ingest path was the global 11 MB
  `Plug.Parsers` body limit, so one authenticated request could insert a single
  ~11 MB `message` or ~100k rows in a single `insert_all` — and every entry was
  ALSO re-emitted into the server log pipeline, billing the same bytes twice.
  """
  use Engram.DataCase, async: true

  import ExUnit.CaptureLog

  alias Engram.Logs

  defp entry(over \\ %{}) do
    Map.merge(
      %{
        "ts" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "level" => "info",
        "category" => "channel",
        "message" => "hello"
      },
      over
    )
  end

  describe "batch size" do
    test "caps the number of rows a single request can insert" do
      user = insert(:user)
      entries = for i <- 1..1_200, do: entry(%{"message" => "m#{i}"})

      capture_log(fn -> assert {:ok, 1_000} = Logs.insert_logs(user, entries) end)
    end

    test "warns with the dropped count rather than failing the request" do
      user = insert(:user)
      entries = for i <- 1..1_050, do: entry(%{"message" => "m#{i}"})

      log = capture_log(fn -> assert {:ok, 1_000} = Logs.insert_logs(user, entries) end)

      assert log =~ "client log batch truncated"
      assert log =~ "dropped 50"
    end

    test "a batch at exactly the cap is untouched and logs nothing" do
      user = insert(:user)
      entries = for i <- 1..1_000, do: entry(%{"message" => "m#{i}"})

      log = capture_log(fn -> assert {:ok, 1_000} = Logs.insert_logs(user, entries) end)

      refute log =~ "truncated"
    end
  end

  describe "field length" do
    test "truncates an oversized message" do
      user = insert(:user)
      huge = String.duplicate("a", 20_000)

      capture_log(fn ->
        assert {:ok, 1} = Logs.insert_logs(user, [entry(%{"message" => huge})])
      end)

      {:ok, [row]} = Logs.list_logs(user, [])
      assert String.length(row.message) == 8_000
    end

    test "truncates an oversized stack" do
      user = insert(:user)
      huge = String.duplicate("s", 40_000)

      capture_log(fn -> assert {:ok, 1} = Logs.insert_logs(user, [entry(%{"stack" => huge})]) end)

      {:ok, [row]} = Logs.list_logs(user, [])
      assert String.length(row.stack) == 16_000
    end

    test "hard-caps the identifier fields" do
      user = insert(:user)
      huge = String.duplicate("x", 5_000)

      capture_log(fn ->
        assert {:ok, 1} =
                 Logs.insert_logs(user, [
                   entry(%{"device_id" => huge, "conn_id" => huge, "platform" => huge})
                 ])
      end)

      {:ok, [row]} = Logs.list_logs(user, [])
      assert String.length(row.device_id) == 128
      assert String.length(row.conn_id) == 128
      assert String.length(row.platform) == 128
    end

    test "leaves a normal entry byte-for-byte alone" do
      user = insert(:user)

      capture_log(fn ->
        assert {:ok, 1} =
                 Logs.insert_logs(user, [
                   entry(%{"message" => "opened", "conn_id" => "c1", "device_id" => "d1"})
                 ])
      end)

      {:ok, [row]} = Logs.list_logs(user, [])
      assert row.message == "opened"
      assert row.conn_id == "c1"
      assert row.device_id == "d1"
    end

    # Truncation counts CHARACTERS, not bytes — slicing a multi-byte codepoint
    # in half would store invalid UTF-8 and (per #739) that is a whole class of
    # its own to clean up afterwards.
    test "never splits a multi-byte codepoint" do
      user = insert(:user)
      huge = String.duplicate("é", 20_000)

      capture_log(fn ->
        assert {:ok, 1} = Logs.insert_logs(user, [entry(%{"message" => huge})])
      end)

      {:ok, [row]} = Logs.list_logs(user, [])
      assert String.valid?(row.message)
      assert String.length(row.message) == 8_000
    end
  end

  describe "re-emit" do
    # The re-emit path ships every entry onward to FireLens -> Loki/CloudWatch.
    # Truncating only on the way to Postgres would still pay for the full
    # oversized message downstream.
    # Uses level "warn" deliberately: client severity is capped at :warning on
    # re-emit, and the test env's Logger level filters :info out entirely, so an
    # "info" entry would capture nothing and the assertion would pass vacuously.
    test "the Logger re-emit carries the TRUNCATED message, not the original" do
      user = insert(:user)
      huge = String.duplicate("z", 20_000)

      log =
        capture_log(fn ->
          Logs.insert_logs(user, [entry(%{"level" => "warn", "message" => huge})])
        end)

      assert log =~ "[client:channel]"
      # The original was 20k. If the re-emit used the raw entry rather than the
      # bounded one, the full string would be here and billed downstream twice.
      refute log =~ String.duplicate("z", 8_001)
      assert log =~ String.duplicate("z", 8_000)
    end
  end

  describe "input shapes" do
    test "still accepts atom-keyed entries from internal callers" do
      user = insert(:user)

      capture_log(fn ->
        assert {:ok, 1} =
                 Logs.insert_logs(user, [
                   %{level: "warn", category: "sync", message: "atom keyed", device_id: "d9"}
                 ])
      end)

      {:ok, [row]} = Logs.list_logs(user, [])
      assert row.message == "atom keyed"
      assert row.device_id == "d9"
    end

    test "an empty batch is still a no-op" do
      user = insert(:user)
      assert {:ok, 0} = Logs.insert_logs(user, [])
    end
  end
end
