defmodule EngramWeb.VaultAccessSocketAttackTest do
  @moduledoc """
  Attack regressions, WebSocket half (imported from a red-team pass): a read-level or none-level vault must not be
  writable (crdt:) or readable (sync:/crdt:) through the socket, and a PATCH
  that narrows a credential must not leave a socket with its old reach.
  """
  use EngramWeb.ChannelCase, async: false

  alias Engram.{Accounts, Crypto, Vaults}

  setup do
    user = insert(:user, external_id: "test-#{Ecto.UUID.generate()}")
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    insert(:user_limit_override, user: user, key: "api_rps_cap", value: %{"v" => 1000})
    insert(:user_limit_override, user: user, key: "api_write_enabled", value: %{"v" => true})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, w, _} = Vaults.register_vault(user, "W", Ecto.UUID.generate())
    {:ok, r, _} = Vaults.register_vault(user, "R", Ecto.UUID.generate())
    {:ok, n, _} = Vaults.register_vault(user, "N", Ecto.UUID.generate())

    access =
      {%{to_string(w.id) => "write", to_string(r.id) => "read", to_string(n.id) => "none"},
       "none"}

    %{user: user, w: w, r: r, n: n, access: access}
  end

  defp key_socket(raw) do
    {:ok, socket} = connect(EngramWeb.UserSocket, %{"token" => raw})
    socket
  end

  defp crdt_join(socket, user, vault),
    do:
      subscribe_and_join(socket, EngramWeb.CrdtChannel, "crdt:#{user.id}:#{vault.id}", %{
        "crdt_proto" => 2
      })

  defp sync_join(socket, user, vault),
    do: subscribe_and_join(socket, EngramWeb.SyncChannel, "sync:#{user.id}:#{vault.id}")

  test "leveled key: crdt join refused on R and N, allowed on W", ctx do
    {:ok, raw, _} = Accounts.create_api_key(ctx.user, "k", ctx.access)
    s = key_socket(raw)
    assert {:ok, _, _} = crdt_join(s, ctx.user, ctx.w)
    assert {:error, %{reason: "read_only_vault"}} = crdt_join(s, ctx.user, ctx.r)
    assert {:error, _} = crdt_join(s, ctx.user, ctx.n)
  end

  test "leveled key: sync join allowed on R (read), refused on N", ctx do
    {:ok, raw, _} = Accounts.create_api_key(ctx.user, "k", ctx.access)
    s = key_socket(raw)
    assert {:ok, _, _} = sync_join(s, ctx.user, ctx.r)
    assert {:error, _} = sync_join(s, ctx.user, ctx.n)
  end

  test "a NONE vault's join answers like a random uuid (sync and crdt)", ctx do
    {:ok, raw, _} = Accounts.create_api_key(ctx.user, "k", ctx.access)
    s = key_socket(raw)
    fake = %{id: Ecto.UUID.generate()}

    for join <- [&sync_join/3, &crdt_join/3] do
      real = join.(s, ctx.user, ctx.n)
      assert {:error, %{reason: "vault_not_found"}} = real
      assert real == join.(s, ctx.user, fake)
    end
  end

  test "legacy key: a join outside its list answers like a random uuid", ctx do
    {:ok, raw, key} = Accounts.create_api_key(ctx.user, "legacy", nil)

    Engram.Repo.insert_all("api_key_vaults", [
      %{api_key_id: Ecto.UUID.dump!(key.id), vault_id: Ecto.UUID.dump!(ctx.w.id)}
    ])

    Engram.Cache.evict(:api_key, key.key_hash)
    s = key_socket(raw)
    fake = %{id: Ecto.UUID.generate()}

    for join <- [&sync_join/3, &crdt_join/3] do
      assert {:error, %{reason: "vault_not_found"}} = join.(s, ctx.user, ctx.n)
      assert join.(s, ctx.user, ctx.n) == join.(s, ctx.user, fake)
    end
  end

  test "sync: inbound events cannot write", ctx do
    {:ok, raw, _} = Accounts.create_api_key(ctx.user, "k", ctx.access)
    {:ok, _, chan} = ctx.user |> then(fn _ -> key_socket(raw) end) |> sync_join(ctx.user, ctx.r)
    ref = push(chan, "push_note", %{"path" => "x.md", "content" => "pwn"})
    assert_reply ref, :error, %{"reason" => "gone"}
    assert {:error, :not_found} = Engram.Notes.get_note(ctx.user, ctx.r, "x.md")
  end

  test "PATCH narrowing W->read: a fresh crdt join is refused at once", ctx do
    {:ok, raw, key} = Accounts.create_api_key(ctx.user, "k", ctx.access)
    s = key_socket(raw)
    assert {:ok, _, _} = crdt_join(s, ctx.user, ctx.w)

    EngramWeb.Endpoint.subscribe("user_socket:#{ctx.user.id}")

    {:ok, _} =
      Accounts.update_api_key_access(
        ctx.user,
        key.id,
        {%{to_string(ctx.w.id) => "read"}, "none"}
      )

    # Live sockets are told to disconnect...
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 1_000
    # ...and the same (cached) socket assigns cannot re-join for write.
    assert {:error, %{reason: "read_only_vault"}} = crdt_join(s, ctx.user, ctx.w)
  end

  # The disconnect broadcast above is best-effort: a channel that missed it
  # (here: a test socket, which never acts on it) must still not write.
  test "PATCH narrowing W->read: an already-joined crdt channel stops writing", ctx do
    {:ok, raw, key} = Accounts.create_api_key(ctx.user, "k", ctx.access)
    {:ok, _, chan} = crdt_join(key_socket(raw), ctx.user, ctx.w)
    Ecto.Adapters.SQL.Sandbox.allow(Engram.Repo, self(), chan.channel_pid)
    # Control: the same frame writes while the key is still write.
    ref0 = push(chan, "crdt_create", %{"doc_id" => Ecto.UUID.generate(), "path" => "ok.md"})
    assert_reply ref0, :ok, _, 10_000

    {:ok, _} =
      Accounts.update_api_key_access(
        ctx.user,
        key.id,
        {%{to_string(ctx.w.id) => "read"}, "none"}
      )

    # The refusal stops the channel (the client rejoins and is refused there).
    Process.unlink(chan.channel_pid)
    mon = Process.monitor(chan.channel_pid)
    ref = push(chan, "crdt_create", %{"doc_id" => Ecto.UUID.generate(), "path" => "pwn.md"})
    assert_reply ref, :error, %{reason: "read_only_vault"}, 10_000
    assert_receive {:DOWN, ^mon, :process, _, {:shutdown, :access_changed}}
    assert {:error, :not_found} = Engram.Notes.get_note(ctx.user, ctx.w, "pwn.md")
  end

  test "legacy key restricted to W: crdt join on R/N refused", ctx do
    {:ok, raw, key} = Accounts.create_api_key(ctx.user, "legacy", nil)

    Engram.Repo.insert_all("api_key_vaults", [
      %{api_key_id: Ecto.UUID.dump!(key.id), vault_id: Ecto.UUID.dump!(ctx.w.id)}
    ])

    Engram.Cache.evict(:api_key, key.key_hash)
    s = key_socket(raw)
    assert {:ok, _, _} = crdt_join(s, ctx.user, ctx.w)
    assert {:error, _} = crdt_join(s, ctx.user, ctx.r)
  end
end
