defmodule Engram.SearchTenantIdfTest do
  @moduledoc """
  Per-tenant IDF on the keyword leg (plan Task 14.1, spec K4): the sparse
  leg narrows Qdrant's IDF corpus to the user's own points. Off unless
  `:tenant_idf` is set (go time, review 2094 H1); then only on Qdrant
  >= 1.19.0 (older servers reject the param) and only for a user holding
  at least `:tenant_idf_min_points` points (below that per-tenant N is
  noise, so global IDF stays).
  """
  use Engram.DataCase, async: true

  import ExUnit.CaptureLog

  alias Engram.Notes.Chunk
  alias Engram.QdrantFilterView
  alias Engram.QdrantStub
  alias Engram.Repo
  alias Engram.Search
  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  @sparse %{indices: [1, 2], values: [1.0, 1.0]}

  describe "request bodies" do
    test "sparse search carries the user's IDF corpus when asked" do
      body = Qdrant.sparse_search_body(@sparse, user_id: "u1", tenant_idf: true)

      assert QdrantFilterView.legacy_view(body.params.idf.corpus) ==
               %{must: [%{key: "user_id", match: %{value: "u1"}}]}

      assert Map.keys(body.params) == [:idf]
    end

    # #2198: v5 points carry the tenant under `u`, so once the legacy fields
    # are dropped a `user_id` corpus is empty and per-tenant IDF is garbage.
    test "v5 layout with legacy filters off: the IDF corpus filters on `u`" do
      ServiceConfig.put_override(:legacy_filter_fields, false)
      uid = "11111111-2222-3333-4444-555555555555"

      body = Qdrant.sparse_search_body(@sparse, user_id: uid, tenant_idf: true)

      assert body.params.idf.corpus == %{
               must: [%{key: "u", match: %{value: "11111111222233334444555555555555"}}]
             }
    end

    test "sparse search has no params by default" do
      refute Map.has_key?(Qdrant.sparse_search_body(@sparse, user_id: "u1"), :params)
    end

    test "hybrid: only the sparse leg carries the IDF corpus" do
      %{searches: [dense, sparse]} =
        Qdrant.hybrid_search_body([0.1], @sparse, user_id: "u1", tenant_idf: true)

      assert QdrantFilterView.legacy_view(sparse.params.idf.corpus) ==
               %{must: [%{key: "user_id", match: %{value: "u1"}}]}

      refute get_in(dense, [:params, :idf])

      %{searches: [_, plain]} = Qdrant.hybrid_search_body([0.1], @sparse, user_id: "u1")
      refute Map.has_key?(plain, :params)
    end
  end

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:qdrant_search_timeout, 30_000)
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)
    %{bypass: bypass, user: user, vault: vault, note: note}
  end

  defp qdrant_version(bypass, version) do
    Bypass.stub(bypass, "GET", "/", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"title":"qdrant","version":"#{version}"}))
    end)
  end

  defp points(user, note, n) do
    now = DateTime.utc_now(:second)

    rows =
      for pos <- 1..n//1 do
        %{
          id: Ecto.UUID.generate(),
          position: pos,
          char_start: 0,
          char_end: 1,
          qdrant_point_id: Ecto.UUID.generate(),
          note_id: note.id,
          user_id: user.id,
          vault_id: note.vault_id,
          created_at: now
        }
      end

    Repo.insert_all(Chunk, rows)
  end

  describe "tenant_idf?/1" do
    test "off by default, with no Qdrant call", %{bypass: b, user: u, note: n} do
      Bypass.down(b)
      points(u, n, 1_000)
      refute Search.tenant_idf?(u)
    end

    test "on for a 1,000-point user on 1.19", %{bypass: b, user: u, note: n} do
      ServiceConfig.put_override(:tenant_idf, true)
      qdrant_version(b, "1.19.2")
      points(u, n, 1_000)
      assert Search.tenant_idf?(u)
    end

    test "off for a 999-point user on 1.19", %{bypass: b, user: u, note: n} do
      ServiceConfig.put_override(:tenant_idf, true)
      qdrant_version(b, "1.19.0")
      points(u, n, 999)
      refute Search.tenant_idf?(u)
    end

    test "off on 1.18 whatever the count", %{bypass: b, user: u, note: n} do
      ServiceConfig.put_override(:tenant_idf, true)
      qdrant_version(b, "1.18.2")
      points(u, n, 1_000)
      refute Search.tenant_idf?(u)
    end

    test "the threshold is a ServiceConfig knob", %{bypass: b, user: u, note: n} do
      ServiceConfig.put_override(:tenant_idf, true)
      ServiceConfig.put_override(:tenant_idf_min_points, 2)
      qdrant_version(b, "1.19.2")
      points(u, n, 2)
      assert Search.tenant_idf?(u)
    end

    # Review 2094 M2: an unreadable version is cached as unknown (< 1.19),
    # so search probes `GET /` at most once per TTL and warns once.
    test "an unreadable version is probed once and warned once", %{bypass: b, user: u} do
      ServiceConfig.put_override(:tenant_idf, true)
      {:ok, probes} = Agent.start_link(fn -> 0 end)

      Bypass.stub(b, "GET", "/", fn conn ->
        Agent.update(probes, &(&1 + 1))
        Plug.Conn.send_resp(conn, 503, "")
      end)

      log =
        capture_log(fn ->
          refute Search.tenant_idf?(u)
          refute Search.tenant_idf?(u)
        end)

      assert Agent.get(probes, & &1) == 1
      assert length(String.split(log, "tenant idf: qdrant version unknown")) == 2
    end

    # Review 2094 M3: the count is cached per user, not read per search.
    test "the user's point count is cached", %{bypass: b, user: u, note: n} do
      ServiceConfig.put_override(:tenant_idf, true)
      qdrant_version(b, "1.19.2")
      points(u, n, 999)
      refute Search.tenant_idf?(u)
      # Another note: positions are unique per note.
      points(u, insert(:note, user: u, vault: Repo.preload(n, :vault).vault), 1)
      refute Search.tenant_idf?(u)
    end
  end

  # Review 2094 M1: the wiring through `Search.search/4`, per mode.
  describe "Search.search/4" do
    setup %{bypass: b, user: u, note: n} do
      QdrantStub.stub_retrieve(b)
      qdrant_version(b, "1.19.2")
      ServiceConfig.put_override(:tenant_idf_min_points, 1)
      points(u, n, 1)

      Mox.stub(Engram.MockEmbedder, :embed_texts, fn _texts, _opts -> {:ok, [[0.1, 0.2]]} end)
      :ok
    end

    defp capture(bypass, path) do
      test = self()

      Bypass.expect_once(bypass, "POST", "/collections/engram_notes" <> path, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        json = Jason.decode!(body)
        send(test, {:qdrant_body, json})
        result = %{"result" => %{"points" => []}}
        resp = if path == "/points/query/batch", do: QdrantStub.batch(conn, result), else: result

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(resp))
      end)
    end

    defp corpus(user), do: %{"must" => [%{"key" => "user_id", "match" => %{"value" => user.id}}]}

    test "keyword mode sends the requesting user's IDF corpus", %{bypass: b, user: u, vault: v} do
      ServiceConfig.put_override(:tenant_idf, true)
      capture(b, "/points/query")
      assert {:ok, []} = Search.search(u, v, "paddle", mode: :keyword)
      assert_received {:qdrant_body, %{"using" => "keyword"} = json}
      assert QdrantFilterView.legacy_view(json["params"]["idf"]["corpus"]) == corpus(u)
    end

    test "hybrid mode: only the keyword leg carries it", %{bypass: b, user: u, vault: v} do
      ServiceConfig.put_override(:tenant_idf, true)
      capture(b, "/points/query/batch")
      assert {:ok, []} = Search.search(u, v, "paddle", mode: :hybrid)
      assert_received {:qdrant_body, %{"searches" => [dense, sparse]}}
      assert QdrantFilterView.legacy_view(sparse["params"]["idf"]["corpus"]) == corpus(u)
      refute get_in(dense, ["params", "idf"])
    end

    test "off: the keyword leg has no IDF corpus", %{bypass: b, user: u, vault: v} do
      capture(b, "/points/query")
      assert {:ok, []} = Search.search(u, v, "paddle", mode: :keyword)
      assert_received {:qdrant_body, json}
      refute Map.has_key?(json, "params")
    end
  end
end
