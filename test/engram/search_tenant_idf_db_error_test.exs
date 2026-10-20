defmodule Engram.SearchTenantIdfDbErrorTest do
  @moduledoc """
  Review 2094 M3: a failed point count (the tenant IDF threshold) falls back
  to global IDF, and the search still answers. Not a 500.
  """
  # async: false: the test renames `chunks` inside its sandbox transaction,
  # an ACCESS EXCLUSIVE lock other tests' connections would wait on.
  use Engram.DataCase, async: false

  import ExUnit.CaptureLog

  alias Engram.QdrantStub
  alias Engram.Repo
  alias Engram.Search
  alias Engram.ServiceConfig

  setup do
    bypass = Bypass.open()
    QdrantStub.stub_retrieve(bypass)
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:qdrant_search_timeout, 30_000)
    ServiceConfig.put_override(:tenant_idf, true)
    ServiceConfig.put_override(:tenant_idf_min_points, 1)

    Bypass.stub(bypass, "GET", "/", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"title":"qdrant","version":"1.19.2"}))
    end)

    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    %{bypass: bypass, user: user, vault: vault}
  end

  test "a DB error in the count uses global IDF and still returns results",
       %{bypass: bypass, user: user, vault: vault} do
    {:ok, enc} =
      Engram.Crypto.encrypt_qdrant_payload(
        %{text: "paddle rotation", title: "Ops", heading_path: "Ops"},
        user,
        "engram_notes",
        "uuid-db-1"
      )

    point = %{
      "id" => "uuid-db-1",
      "score" => 0.5,
      "payload" => %{
        "text" => enc.text,
        "title" => enc.title,
        "heading_path" => enc.heading_path,
        "text_nonce" => enc.text_nonce,
        "title_nonce" => enc.title_nonce,
        "heading_path_nonce" => enc.heading_path_nonce,
        "aad_version" => enc.aad_version,
        "source_path" => "Ops.md",
        "user_id" => to_string(user.id),
        "vault_id" => to_string(vault.id)
      }
    }

    test = self()

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:qdrant_body, Jason.decode!(body)})
      # The count ran before this request; put the table back for the
      # display-field rehydration after it.
      Ecto.Adapters.SQL.Sandbox.allow(Repo, test, self())
      Repo.query!("ALTER TABLE chunks_unavailable RENAME TO chunks")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => %{"points" => [point]}}))
    end)

    # The count's query now fails with undefined_table (a Postgrex.Error).
    Repo.query!("ALTER TABLE chunks RENAME TO chunks_unavailable")

    log =
      capture_log(fn ->
        assert {:ok, [hit]} = Search.search(user, vault, "paddle", mode: :keyword)
        assert hit.text == "paddle rotation"
      end)

    assert log =~ "tenant idf: point count failed, using global idf"
    assert_received {:qdrant_body, json}
    refute Map.has_key?(json, "params")
  end
end
