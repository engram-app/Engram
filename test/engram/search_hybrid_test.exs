defmodule Engram.SearchHybridTest do
  use Engram.DataCase, async: false

  import Mox
  import Ecto.Query

  alias Engram.Crypto.DekCache
  alias Engram.Search

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)
    {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
    vault = insert(:vault, user: user)
    %{bypass: bypass, user: user, vault: vault}
  end

  test "mode: :hybrid sends a fused dense+keyword query and returns results",
       %{bypass: bypass, user: user, vault: vault} do
    Engram.MockEmbedder
    |> expect(:embed_texts, fn ["paddle_api_key"], _opts -> {:ok, [[0.1, 0.2, 0.3]]} end)

    {:ok, enc} =
      Engram.Crypto.encrypt_qdrant_payload(
        %{text: "PADDLE_API_KEY rotation", title: "Ops", heading_path: "Ops"},
        user,
        "engram_notes",
        "uuid-1"
      )

    fused = %{
      "result" => %{
        "points" => [
          %{
            "id" => "uuid-1",
            "score" => 0.0163,
            "payload" =>
              Map.merge(
                %{
                  "text" => enc.text,
                  "title" => enc.title,
                  "heading_path" => enc.heading_path,
                  "text_nonce" => enc.text_nonce,
                  "title_nonce" => enc.title_nonce,
                  "heading_path_nonce" => enc.heading_path_nonce,
                  "aad_version" => enc.aad_version
                },
                %{"user_id" => to_string(user.id), "vault_id" => to_string(vault.id)}
              )
          }
        ]
      }
    }

    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["query"]["fusion"] == "rrf"
      assert length(json["prefetch"]) == 2

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(fused))
    end)

    assert {:ok, [hit]} = Search.search(user, vault, "paddle_api_key", mode: :hybrid)
    assert hit.text == "PADDLE_API_KEY rotation"
    assert_in_delta hit.score, 0.0163, 1.0e-6
  end

  test "internal default mode stays :vector (single-leg query)",
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

    assert {:ok, []} = Search.search(user, vault, "x")
  end

  test "mode: :keyword routes to a sparse-only query and returns results",
       %{bypass: bypass, user: user, vault: vault} do
    # Keyword mode must NOT call the embedder at all.
    Mox.expect(Engram.MockEmbedder, :embed_texts, 0, fn _, _ -> {:ok, []} end)

    {:ok, enc} =
      Engram.Crypto.encrypt_qdrant_payload(
        %{text: "paddle_api_key rotation", title: "Ops", heading_path: "Ops"},
        user,
        "engram_notes",
        "uuid-kw-1"
      )

    sparse_result = %{
      "result" => %{
        "points" => [
          %{
            "id" => "uuid-kw-1",
            "score" => 0.85,
            "payload" =>
              Map.merge(
                %{
                  "text" => enc.text,
                  "title" => enc.title,
                  "heading_path" => enc.heading_path,
                  "text_nonce" => enc.text_nonce,
                  "title_nonce" => enc.title_nonce,
                  "heading_path_nonce" => enc.heading_path_nonce,
                  "aad_version" => enc.aad_version
                },
                %{"user_id" => to_string(user.id), "vault_id" => to_string(vault.id)}
              )
          }
        ]
      }
    }

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
