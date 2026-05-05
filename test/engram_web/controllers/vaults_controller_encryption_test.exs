defmodule EngramWeb.VaultsControllerEncryptionTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts

  setup %{conn: conn} do
    user = insert(:user, encryption_toggle_cooldown_days: 7)
    insert(:user_override, user: user, overrides: %{"max_vaults" => 10})
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    conn = put_req_header(conn, "authorization", "Bearer #{raw_key}")
    {:ok, conn: conn, user: user}
  end

  describe "POST /api/vaults/:id/encrypt" do
    test "202 with updated vault on success", %{conn: conn, user: user} do
      vault = insert(:vault, user: user, encrypted: false, encryption_status: "none")
      resp = post(conn, ~p"/api/vaults/#{vault.id}/encrypt")
      json = json_response(resp, 202)
      assert json["vault"]["encryption_status"] == "encrypting"
      assert json["vault"]["cooldown_days"] == 7
    end

    test "202 even within would-be cooldown when user has no cooldown_days", %{
      conn: conn,
      user: user
    } do
      {:ok, _} =
        user
        |> Ecto.Changeset.change(%{encryption_toggle_cooldown_days: nil})
        |> Engram.Repo.update()

      recent = DateTime.utc_now() |> DateTime.add(-1, :day)

      vault =
        insert(:vault,
          user: user,
          encrypted: false,
          encryption_status: "none",
          last_toggle_at: recent
        )

      resp = post(conn, ~p"/api/vaults/#{vault.id}/encrypt")
      json = json_response(resp, 202)
      assert json["vault"]["encryption_status"] == "encrypting"
      assert json["vault"]["cooldown_days"] == nil
    end

    test "429 on cooldown", %{conn: conn, user: user} do
      recent = DateTime.utc_now() |> DateTime.add(-3, :day)

      vault =
        insert(:vault,
          user: user,
          encrypted: false,
          encryption_status: "none",
          last_toggle_at: recent
        )

      resp = post(conn, ~p"/api/vaults/#{vault.id}/encrypt")
      json = json_response(resp, 429)
      assert json["error"] == "cooldown_active"
      assert json["retry_after"]
    end

    test "409 when already encrypted", %{conn: conn, user: user} do
      vault = insert(:vault, user: user, encrypted: true, encryption_status: "encrypted")
      resp = post(conn, ~p"/api/vaults/#{vault.id}/encrypt")
      json = json_response(resp, 409)
      assert json["error"] == "invalid_status_transition"
    end

    test "403 or 404 when not vault owner", %{conn: conn} do
      other = insert(:user)
      insert(:user_override, user: other, overrides: %{"max_vaults" => 5})
      vault = insert(:vault, user: other, encrypted: false, encryption_status: "none")
      resp = post(conn, ~p"/api/vaults/#{vault.id}/encrypt")
      assert resp.status in [403, 404]
    end
  end

  describe "POST /api/vaults/:id/decrypt" do
    test "202 and schedules decrypt", %{conn: conn, user: user} do
      old = DateTime.utc_now() |> DateTime.add(-8, :day)

      vault =
        insert(:vault,
          user: user,
          encrypted: true,
          encryption_status: "encrypted",
          last_toggle_at: old
        )

      resp = post(conn, ~p"/api/vaults/#{vault.id}/decrypt")
      json = json_response(resp, 202)
      assert json["vault"]["encryption_status"] == "decrypt_pending"
      assert json["vault"]["decrypt_requested_at"]
    end
  end

  describe "DELETE /api/vaults/:id/decrypt" do
    test "202 cancels pending decrypt", %{conn: conn, user: user} do
      vault =
        insert(:vault,
          user: user,
          encrypted: true,
          encryption_status: "decrypt_pending",
          decrypt_requested_at: DateTime.utc_now(),
          last_toggle_at: DateTime.utc_now()
        )

      resp = delete(conn, ~p"/api/vaults/#{vault.id}/decrypt")
      json = json_response(resp, 202)
      assert json["vault"]["encryption_status"] == "encrypted"
    end

    test "409 when nothing to cancel", %{conn: conn, user: user} do
      vault = insert(:vault, user: user, encrypted: true, encryption_status: "encrypted")
      resp = delete(conn, ~p"/api/vaults/#{vault.id}/decrypt")
      assert json_response(resp, 409)
    end
  end

  describe "GET /api/vaults/:id/encryption_progress" do
    test "returns processed/total counts", %{conn: conn, user: user} do
      vault = insert(:vault, user: user, encrypted: true, encryption_status: "encrypting")

      insert(:note,
        user: user,
        vault: vault,
        content_ciphertext: <<1, 2, 3>>,
        content_nonce: <<4, 5>>
      )

      insert(:note, user: user, vault: vault, content: "plain")

      resp = get(conn, ~p"/api/vaults/#{vault.id}/encryption_progress")
      json = json_response(resp, 200)
      assert json["total"] == 2
      assert json["processed"] == 1
      assert json["status"] == "encrypting"
    end
  end
end
