defmodule Engram.SyncTest do
  use Engram.DataCase, async: true

  alias Engram.Sync
  alias Engram.Sync.DeviceCursor
  alias Engram.Vaults

  test "cursor round-trips (seq,id) and rejects garbage" do
    id = Ecto.UUID.generate()
    tok = Sync.encode_cursor(42, id)
    assert {:ok, {42, ^id}} = Sync.decode_cursor(tok)
    assert {:ok, nil} = Sync.decode_cursor(nil)
    assert {:error, :invalid_cursor} = Sync.decode_cursor("not-base64!!")
  end

  test "decode_cursor rejects well-formed base64 with malformed payloads" do
    # valid base64, but no ":" separator
    assert {:error, :invalid_cursor} = Sync.decode_cursor(Base.url_encode64("42", padding: false))
    # non-integer seq
    bad_seq = Base.url_encode64("x:#{Ecto.UUID.generate()}", padding: false)
    assert {:error, :invalid_cursor} = Sync.decode_cursor(bad_seq)
    # non-UUID id
    assert {:error, :invalid_cursor} =
             Sync.decode_cursor(Base.url_encode64("42:not-a-uuid", padding: false))

    # non-binary, non-nil arg hits the catch-all clause
    assert {:error, :invalid_cursor} = Sync.decode_cursor(42)
  end

  test "record_cursor upserts a monotonic watermark per (vault, device)" do
    user = insert_user()
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "T"})

    :ok = Sync.record_cursor(user, vault, "dev-1", 10)
    :ok = Sync.record_cursor(user, vault, "dev-1", 25)
    # lagging pull must NOT regress the watermark
    :ok = Sync.record_cursor(user, vault, "dev-1", 20)

    {:ok, row} =
      Repo.with_tenant(user.id, fn ->
        Repo.get_by(DeviceCursor, vault_id: vault.id, device_id: "dev-1")
      end)

    assert row.last_seq == 25
  end

  test "record_cursor with nil device_id is a no-op" do
    user = insert_user()
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "T"})
    assert :ok = Sync.record_cursor(user, vault, nil, 5)
  end
end
