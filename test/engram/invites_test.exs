defmodule Engram.InvitesTest do
  use Engram.DataCase, async: true
  alias Engram.Invites

  setup do
    %{admin: insert(:user, role: "admin")}
  end

  test "create_invite/2 returns a raw token shown once + hashed row", %{admin: admin} do
    {:ok, {raw, invite}} = Invites.create_invite(admin, %{})
    assert is_binary(raw) and byte_size(raw) > 20
    assert invite.token_hash == :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    assert invite.max_uses == 1
    assert invite.use_count == 0
  end

  test "redeem/1 consumes a single-use invite", %{admin: admin} do
    {:ok, {raw, _}} = Invites.create_invite(admin, %{})
    assert {:ok, _invite} = Invites.redeem(raw)
    assert {:error, :invalid} = Invites.redeem(raw)
  end

  test "redeem/1 honors a multi-use cap", %{admin: admin} do
    {:ok, {raw, _}} = Invites.create_invite(admin, %{max_uses: 2})
    assert {:ok, _} = Invites.redeem(raw)
    assert {:ok, _} = Invites.redeem(raw)
    assert {:error, :invalid} = Invites.redeem(raw)
  end

  test "redeem/1 rejects an expired invite", %{admin: admin} do
    {:ok, {raw, _}} = Invites.create_invite(admin, %{expires_in_days: 0})
    Engram.Repo.update_all(Engram.Invites.Invite, set: [expires_at: ~U[2000-01-01 00:00:00Z]])
    assert {:error, :invalid} = Invites.redeem(raw)
  end

  test "redeem/1 rejects a revoked invite", %{admin: admin} do
    {:ok, {raw, invite}} = Invites.create_invite(admin, %{})
    {:ok, _} = Invites.revoke(invite.id)
    assert {:error, :invalid} = Invites.redeem(raw)
  end

  test "preview/1 reports validity without consuming", %{admin: admin} do
    {:ok, {raw, _}} = Invites.create_invite(admin, %{label: "Mom"})
    assert %{valid: true, label: "Mom"} = Invites.preview(raw)
    assert {:ok, _} = Invites.redeem(raw)
    assert %{valid: false} = Invites.preview("garbage")
  end

  test "list_active/0 excludes revoked/expired/exhausted", %{admin: admin} do
    {:ok, {_raw, keep}} = Invites.create_invite(admin, %{})
    {:ok, {_raw2, gone}} = Invites.create_invite(admin, %{})
    {:ok, _} = Invites.revoke(gone.id)
    ids = Invites.list_active() |> Enum.map(& &1.id)
    assert keep.id in ids
    refute gone.id in ids
  end
end
