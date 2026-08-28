defmodule Engram.Vector.QdrantEnsureCollectionMemoTest do
  # Guard: `ensure_collection/2` must hit the network ONCE per node, not once
  # per note.
  #
  # `Indexing.prepare_index/3` calls it for every note. On an existing
  # collection the work is two round trips that cannot produce a different
  # answer — a PUT that 409s, then a `collection_info` GET to verify shape.
  # Measured in prod 2026-08-28: 853 `ensure_collection` and 853
  # `collection_info` calls against 853 upserts, a 1:1:1 ratio, sitting inside
  # the slowest queue we have (embed averages 738 ms). See #1501.
  #
  # The second test is the one that matters more. Memoising a FAILURE would
  # cache one transient Qdrant blip for the life of the node and break every
  # subsequent index against a collection that was perfectly fine — a far worse
  # bug than the round trips this removes.
  use ExUnit.Case, async: false

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  setup do
    # Node-wide memo: clear it around each test so ordering cannot leak a
    # "ready" marker from one case into another.
    Qdrant.forget_collection_memo()
    on_exit(&Qdrant.forget_collection_memo/0)

    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Bypass.stub(bypass, "PUT", "/collections/:col/index", fn conn ->
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
    end)

    %{bypass: bypass}
  end

  test "repeated calls make exactly one network round trip", %{bypass: bypass} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.stub(bypass, "PUT", "/collections/memo_col", fn conn ->
      Agent.update(counter, &(&1 + 1))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    for _ <- 1..25, do: assert(:ok = Qdrant.ensure_collection("memo_col", 1024))

    calls = Agent.get(counter, & &1)

    assert calls == 1,
           "25 ensure_collection/2 calls produced #{calls} network round trips, expected 1.\n" <>
             "This runs per NOTE during indexing, so anything above 1 is paid per note for\n" <>
             "the life of the collection. See #1501."
  end

  test "a failure is NOT memoised — the next caller retries", %{bypass: bypass} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.stub(bypass, "PUT", "/collections/flaky_col", fn conn ->
      n = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

      if n == 1 do
        # First call fails, as a transient Qdrant blip would.
        Plug.Conn.send_resp(conn, 500, ~s({"status":"error"}))
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"result": true}))
      end
    end)

    assert {:error, _} = Qdrant.ensure_collection("flaky_col", 1024)

    assert :ok = Qdrant.ensure_collection("flaky_col", 1024),
           "the failure was memoised: a single transient error would poison this node\n" <>
             "for its whole life and every later index would fail against a healthy\n" <>
             "collection. Only success may be cached."

    assert Agent.get(counter, & &1) == 2,
           "expected exactly 2 round trips — one failing, one retry that succeeds."
  end

  test "a different collection or dims is a separate memo entry", %{bypass: bypass} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Bypass.stub(bypass, "PUT", "/collections/:col", fn conn ->
      Agent.update(counter, &(&1 + 1))

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    assert :ok = Qdrant.ensure_collection("col_a", 1024)
    assert :ok = Qdrant.ensure_collection("col_b", 1024)
    assert :ok = Qdrant.ensure_collection("col_a", 512)

    assert Agent.get(counter, & &1) == 3,
           "the memo key must include collection AND dims — collapsing them would skip\n" <>
             "creating a genuinely new collection, or skip a dimension change."
  end
end
