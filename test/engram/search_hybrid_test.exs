defmodule Engram.SearchHybridTest do
  use Engram.DataCase, async: false

  import Mox

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
end
