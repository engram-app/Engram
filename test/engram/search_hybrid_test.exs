defmodule Engram.SearchHybridTest do
  use Engram.DataCase, async: true

  import Mox
  import Ecto.Query
  import Engram.Fixtures, only: [insert_chunk!: 4, insert_note!: 3]

  alias Engram.Crypto.DekCache
  alias Engram.QdrantStub
  alias Engram.Search
  alias Engram.ServiceConfig

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Engram.QdrantStub.stub_retrieve(bypass)
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    # The search path's prod budget is 5s (`:qdrant_search_timeout`), tuned for
    # a real network. These tests assert query SHAPE, and a localhost Bypass
    # round trip can pass 5s through pure scheduler starvation on a loaded box
    # — surfacing as `%Req.TransportError{reason: :timeout}`, which reads like
    # a query-construction bug.
    ServiceConfig.put_override(:qdrant_search_timeout, 30_000)
    {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
    vault = insert(:vault, user: user)
    %{bypass: bypass, user: user, vault: vault}
  end

  test "mode: :hybrid sends a fused dense+keyword query and returns results",
       %{bypass: bypass, user: user, vault: vault} do
    Engram.MockEmbedder
    |> expect(:embed_texts, fn ["paddle_api_key"], _opts -> {:ok, [[0.1, 0.2, 0.3]]} end)

    point = hit_point(user, vault, "Ops", Ecto.UUID.generate(), 0.0163, "PADDLE_API_KEY rotation")
    fused = %{"result" => %{"points" => [point]}}

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert Enum.map(json["searches"], & &1["using"]) == ["dense", "keyword"]
      assert length(json["searches"]) == 2

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(QdrantStub.batch(conn, fused)))
    end)

    assert {:ok, [hit]} = Search.search(user, vault, "paddle_api_key", mode: :hybrid)
    assert hit.text == "PADDLE_API_KEY rotation"
    assert hit.score == QdrantStub.rrf(0)
  end

  # A point on its own note `<name>.md`: the chunk row holds the text, the
  # note row the title.
  defp hit_point(user, vault, name, id, score, text \\ nil) do
    note = insert_note!(user, vault, %{path: "#{name}.md", title: name})
    insert_chunk!(user, note, id, text: text || "text #{name}")
    %{"id" => id, "score" => score}
  end

  # End to end through Search: a point in BOTH legs is returned once with the
  # summed score, and a cross-leg tie (dense rank 1 vs keyword rank 1) breaks
  # by id, never by the keyword leg's larger raw BM25 score.
  test "a point in both legs fuses once; a cross-leg rank tie breaks by id",
       %{bypass: bypass, user: user, vault: vault} do
    Engram.MockEmbedder
    |> expect(:embed_texts, fn ["iron"], _opts -> {:ok, [[0.1, 0.2, 0.3]]} end)

    # Fixed ids, ordered as the names: the tie breaks on the id.
    [aa, mm, zz] =
      for d <- ~w(1 5 9), do: String.duplicate(d, 8) <> "-0000-4000-8000-000000000000"

    both_dense = hit_point(user, vault, "mm-both", mm, 0.9)
    dense = [both_dense, hit_point(user, vault, "aa-dense", aa, 0.8)]
    keyword = [%{both_dense | "score" => 12.0}, hit_point(user, vault, "zz-kw", zz, 9.0)]

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(QdrantStub.batch(conn, %{"result" => dense}, keyword))
      )
    end)

    assert {:ok, results} = Search.search(user, vault, "iron", mode: :hybrid, diversity: 0)
    assert Enum.map(results, & &1.title) == ["mm-both", "aa-dense", "zz-kw"]
    assert hd(results).score == QdrantStub.rrf(0) * 2

    # The text is in Postgres and MMR is off: no retrieve at all.
    assert QdrantStub.last_retrieve(bypass) == nil
  end

  # The default is what MCP's `suggest_folder` and note auto-placement get,
  # since they pass no mode. Dense-only there missed every note indexed
  # sparse-only (an owner whose embed budget ran out), so it is hybrid.
  test "internal default mode is :hybrid (dense + keyword legs)",
       %{bypass: bypass, user: user, vault: vault} do
    Engram.MockEmbedder
    |> expect(:embed_texts, fn ["x"], _opts -> {:ok, [[0.1, 0.2, 0.3]]} end)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query/batch", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert Enum.map(json["searches"], & &1["using"]) |> Enum.sort() == ["dense", "keyword"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result":[{"points":[]},{"points":[]}]}))
    end)

    assert {:ok, []} = Search.search(user, vault, "x")
  end

  test "mode: :vector is a single-leg dense query",
       %{bypass: bypass, user: user, vault: vault} do
    Engram.MockEmbedder
    |> expect(:embed_texts, fn ["x"], _opts -> {:ok, [[0.1, 0.2, 0.3]]} end)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["using"] == "dense"
      refute Map.has_key?(json, "prefetch")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result":[]}))
    end)

    assert {:ok, []} = Search.search(user, vault, "x", mode: :vector)
  end

  test "mode: :keyword routes to a sparse-only query and returns results",
       %{bypass: bypass, user: user, vault: vault} do
    # Keyword mode must NOT call the embedder at all.
    Mox.expect(Engram.MockEmbedder, :embed_texts, 0, fn _, _ -> {:ok, []} end)

    point = hit_point(user, vault, "Ops", Ecto.UUID.generate(), 0.85, "paddle_api_key rotation")
    sparse_result = %{"result" => %{"points" => [point]}}

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      # Sparse-only: uses "keyword" named vector, no prefetch
      assert json["using"] == "keyword"
      refute Map.has_key?(json, "prefetch")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(sparse_result))
    end)

    assert {:ok, [hit]} = Search.search(user, vault, "paddle_api_key", mode: :keyword)
    assert hit.text == "paddle_api_key rotation"
    assert_in_delta hit.score, 0.85, 1.0e-6
  end

  test "mode: :hybrid with no-DEK user degrades to a dense-only query",
       %{bypass: bypass, user: user, vault: vault} do
    # Null the DEK so sparse_query/2 returns :no_vault. Must:
    # 1. Invalidate the DekCache (process-level cache bypasses DB)
    # 2. Reload the user struct (get_dek pattern-matches on encrypted_dek field;
    #    the in-memory struct still carries the old value until reloaded)
    Engram.Repo.update_all(
      from(u in Engram.Accounts.User, where: u.id == ^user.id),
      [set: [encrypted_dek: nil]],
      skip_tenant_check: true
    )

    DekCache.invalidate(user.id)
    nodek_user = Engram.Accounts.get_user!(user.id)

    # Embedding still runs in hybrid mode — the embed-then-degrade path.
    Engram.MockEmbedder
    |> expect(:embed_texts, fn ["search term"], _opts -> {:ok, [[0.1, 0.2, 0.3]]} end)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      # Dense-only fallback: using "dense", no prefetch
      assert json["using"] == "dense"
      refute Map.has_key?(json, "prefetch")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": []}))
    end)

    assert {:ok, []} = Search.search(nodek_user, vault, "search term", mode: :hybrid)
  end

  test "mode: :hybrid with empty/stopword-only query degrades to dense-only",
       %{bypass: bypass, user: user, vault: vault} do
    # "!!!" tokenizes to zero tokens → encode_query returns %{indices: [], values: []}
    # sparse_query/2 (after Fix 1) treats that as :no_vault → hybrid degrades to dense.
    Engram.MockEmbedder
    |> expect(:embed_texts, fn ["!!!"], _opts -> {:ok, [[0.5, 0.6, 0.7]]} end)

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      # Degraded to dense-only: using "dense", no prefetch
      assert json["using"] == "dense"
      refute Map.has_key?(json, "prefetch")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": []}))
    end)

    assert {:ok, []} = Search.search(user, vault, "!!!", mode: :hybrid)
  end
end
