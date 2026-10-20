defmodule Engram.SearchTenantIdfTest do
  @moduledoc """
  Per-tenant IDF on the keyword leg (plan Task 14.1, spec K4): the sparse
  leg narrows Qdrant's IDF corpus to the user's own points, but only on
  Qdrant >= 1.19.0 (older servers reject the param) and only for a user
  holding at least `:tenant_idf_min_points` points (below that per-tenant
  N is noise, so global IDF stays).
  """
  use Engram.DataCase, async: true

  alias Engram.Notes.Chunk
  alias Engram.Repo
  alias Engram.Search
  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  @sparse %{indices: [1, 2], values: [1.0, 1.0]}

  describe "request bodies" do
    test "sparse search carries the user's IDF corpus when asked" do
      body = Qdrant.sparse_search_body(@sparse, user_id: "u1", tenant_idf: true)

      assert body.params == %{
               idf: %{corpus: %{must: [%{key: "user_id", match: %{value: "u1"}}]}}
             }
    end

    test "sparse search has no params by default" do
      refute Map.has_key?(Qdrant.sparse_search_body(@sparse, user_id: "u1"), :params)
    end

    test "hybrid: only the sparse leg carries the IDF corpus" do
      %{searches: [dense, sparse]} =
        Qdrant.hybrid_search_body([0.1], @sparse, user_id: "u1", tenant_idf: true)

      assert sparse.params.idf.corpus == %{must: [%{key: "user_id", match: %{value: "u1"}}]}
      refute get_in(dense, [:params, :idf])

      %{searches: [_, plain]} = Qdrant.hybrid_search_body([0.1], @sparse, user_id: "u1")
      refute Map.has_key?(plain, :params)
    end
  end

  describe "tenant_idf?/1" do
    setup do
      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
      {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
      vault = insert(:vault, user: user)
      note = insert(:note, user: user, vault: vault)
      %{bypass: bypass, user: user, note: note}
    end

    defp qdrant_version(bypass, version) do
      Bypass.stub(bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, ~s({"title":"qdrant","version":"#{version}"}))
      end)
    end

    defp points(user, note, n) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

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

    test "on for a 1,000-point user on 1.19", %{bypass: b, user: u, note: n} do
      qdrant_version(b, "1.19.2")
      points(u, n, 1_000)
      assert Search.tenant_idf?(u)
    end

    test "off for a 999-point user on 1.19", %{bypass: b, user: u, note: n} do
      qdrant_version(b, "1.19.0")
      points(u, n, 999)
      refute Search.tenant_idf?(u)
    end

    test "off on 1.18 whatever the count", %{bypass: b, user: u, note: n} do
      qdrant_version(b, "1.18.2")
      points(u, n, 1_000)
      refute Search.tenant_idf?(u)
    end

    test "off when the server version is unreadable", %{bypass: b, user: u} do
      Bypass.down(b)
      refute Search.tenant_idf?(u)
    end

    test "the threshold is a ServiceConfig knob", %{bypass: b, user: u, note: n} do
      qdrant_version(b, "1.19.2")
      ServiceConfig.put_override(:tenant_idf_min_points, 2)
      points(u, n, 2)
      assert Search.tenant_idf?(u)
    end
  end
end
