defmodule Engram.KeywordStoreTest do
  @moduledoc """
  The keyword store seam (`Engram.KeywordStore`): the default backend, and
  every search path's keyword leg going through it. The write and delete
  paths are asserted in their own suites (`KeywordStoreRecorder`).
  """
  use Engram.DataCase, async: true

  import Mox

  alias Engram.KeywordStore
  alias Engram.KeywordStore.QdrantSparse
  alias Engram.QdrantStub
  alias Engram.Search
  alias Engram.ServiceConfig

  setup :verify_on_exit!

  test "QdrantSparse is the default everywhere, with no config" do
    assert KeywordStore.impl() == QdrantSparse
  end

  test "QdrantSparse keeps the keyword vector on the dense point" do
    sparse = %{indices: <<1::little-32>>, values: <<1.0::little-float-64>>}
    scope = %{user_id: "u", vault_id: "v", note_id: "n"}

    assert KeywordStore.index(scope, [%{id: "p1", sparse: sparse}]) ==
             {:ok, %{"p1" => %{"keyword" => sparse}}, nil}
  end

  test "empty deletes and upserts never reach the backend" do
    Engram.KeywordStoreRecorder.install()
    assert :ok = KeywordStore.delete_points("u", [])
    assert :ok = KeywordStore.upsert(%{user_id: "u", vault_id: "v", note_id: "n"}, [])
    refute_received {:keyword_store, _, _}
  end

  describe "search legs" do
    setup do
      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
      ServiceConfig.put_override(:qdrant_search_timeout, 30_000)
      Engram.KeywordStoreRecorder.install()
      {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
      %{bypass: bypass, user: user, vault: insert(:vault, user: user)}
    end

    test "keyword-only searches the store", %{bypass: bypass, user: user, vault: vault} do
      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        Plug.Conn.send_resp(conn, 200, ~s({"result":{"points":[]}}))
      end)

      assert {:ok, []} = Search.search(user, vault, "ferritin", mode: :keyword)
      assert_received {:keyword_store, :search, [%{indices: [_ | _]}, opts]}
      assert opts[:user_id] == to_string(user.id)
    end

    test "hybrid searches the store in one call", %{bypass: bypass, user: user, vault: vault} do
      expect(Engram.MockEmbedder, :embed_texts, fn _texts, _opts -> {:ok, [[0.1, 0.2]]} end)

      Bypass.expect_once(
        bypass,
        "POST",
        "/collections/engram_notes/points/query/batch",
        fn conn ->
          Plug.Conn.send_resp(conn, 200, Jason.encode!(QdrantStub.batch(conn, %{"result" => []})))
        end
      )

      assert {:ok, []} = Search.search(user, vault, "ferritin", mode: :hybrid)
      assert_received {:keyword_store, :hybrid_search, [[0.1, 0.2], %{indices: [_ | _]}, _opts]}
    end

    test "a failed query embed degrades to the store's keyword search",
         %{bypass: bypass, user: user, vault: vault} do
      expect(Engram.MockEmbedder, :embed_texts, fn _texts, _opts -> {:error, :timeout} end)

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        Plug.Conn.send_resp(conn, 200, ~s({"result":{"points":[]}}))
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, []} = Search.search(user, vault, "ferritin", mode: :hybrid)
      end)

      assert_received {:keyword_store, :search, [%{indices: [_ | _]}, _opts]}
    end
  end
end
