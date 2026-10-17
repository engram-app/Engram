defmodule EngramWeb.VaultAccessSocketAttackTest do
  @moduledoc """
  Attack regressions, WebSocket half (imported from a red-team pass): a read-level or none-level vault must not be
  writable (crdt:) or readable (sync:/crdt:) through the socket, and a PATCH
  that narrows a credential must not leave a socket with its old reach.
  """
  use EngramWeb.ChannelCase, async: false

  import Ecto.Query, only: [from: 2]

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
    assert {:ok, _, joined} = crdt_join(s, ctx.user, ctx.w)
    # The joined channel stops on the narrowing (`ChannelAccess`); not this test's subject.
    Process.unlink(joined.channel_pid)

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

  # An open channel holds its access (`EngramWeb.ChannelAccess`) and is
  # re-judged on the owner's disconnect broadcast, which every narrowing
  # sends, and on a periodic re-check for when that broadcast is lost. Either
  # way a channel that lost its vault stops: no frame in, no broadcast out.
  # A test socket never acts on the disconnect itself, so what stops here is
  # the channel's own judgement.

  # `join`, not `subscribe_and_join`: this test process must hear the topic
  # only through the channel's own fastlane, which goes when the channel does.
  defp sync_join_only(socket, user, vault),
    do: join(socket, EngramWeb.SyncChannel, "sync:#{user.id}:#{vault.id}")

  # A dead channel's PubSub registration is removed asynchronously after its
  # DOWN; wait for that before asserting nothing more is delivered.
  defp await_unsubscribed(topic, pid, tries \\ 50) do
    if Enum.any?(Registry.lookup(Engram.PubSub, topic), fn {p, _} -> p == pid end) and tries > 0 do
      Process.sleep(10)
      await_unsubscribed(topic, pid, tries - 1)
    end
  end

  defp watch(chan) do
    Ecto.Adapters.SQL.Sandbox.allow(Engram.Repo, self(), chan.channel_pid)
    Process.unlink(chan.channel_pid)
    Process.monitor(chan.channel_pid)
  end

  defp patch_access(ctx, key, vault, level),
    do:
      {:ok, _} =
        Accounts.update_api_key_access(
          ctx.user,
          key.id,
          {%{to_string(vault.id) => level}, "none"}
        )

  # The same narrowing with NO broadcast: only the periodic re-check can see it.
  defp narrow_silently(key, vault, level) do
    Engram.Repo.update_all(
      from(v in "api_key_vaults",
        where:
          v.api_key_id == type(^key.id, Ecto.UUID) and v.vault_id == type(^vault.id, Ecto.UUID)
      ),
      [set: [level: level]],
      skip_tenant_check: true
    )

    Engram.Cache.evict_local(:api_key, key.key_hash)
  end

  defp fast_recheck(_ctx) do
    Application.put_env(:engram, :channel_access_recheck_ms, 50)
    on_exit(fn -> Application.delete_env(:engram, :channel_access_recheck_ms) end)
  end

  describe "within the broadcast" do
    test "PATCH W->read stops a joined crdt channel; a later frame writes nothing", ctx do
      {:ok, raw, key} = Accounts.create_api_key(ctx.user, "k", ctx.access)
      {:ok, _, chan} = crdt_join(key_socket(raw), ctx.user, ctx.w)
      mon = watch(chan)

      # Control: the channel writes while the key is write.
      ref = push(chan, "crdt_create", %{"doc_id" => Ecto.UUID.generate(), "path" => "ok.md"})
      assert_reply ref, :ok, _, 10_000

      patch_access(ctx, key, ctx.w, "read")
      assert_receive {:DOWN, ^mon, :process, _, {:shutdown, :access_changed}}, 2_000

      push(chan, "crdt_create", %{"doc_id" => Ecto.UUID.generate(), "path" => "pwn.md"})
      assert {:error, :not_found} = Engram.Notes.get_note(ctx.user, ctx.w, "pwn.md")
    end

    test "PATCH R->none stops a joined sync channel; broadcasts stop reaching it", ctx do
      {:ok, raw, key} = Accounts.create_api_key(ctx.user, "k", ctx.access)
      {:ok, _, chan} = sync_join_only(key_socket(raw), ctx.user, ctx.r)
      topic = "sync:#{ctx.user.id}:#{ctx.r.id}"
      mon = watch(chan)

      EngramWeb.Endpoint.broadcast!(topic, "note_changed", %{"path" => "a.md"})
      assert_push "note_changed", %{"path" => "a.md"}

      patch_access(ctx, key, ctx.r, "none")
      assert_receive {:DOWN, ^mon, :process, _, {:shutdown, :access_changed}}, 2_000
      await_unsubscribed(topic, chan.channel_pid)

      EngramWeb.Endpoint.broadcast!(topic, "note_changed", %{"path" => "secret.md"})
      refute_push "note_changed", %{"path" => "secret.md"}
    end

    test "a disconnect that changes nothing leaves the channel open", ctx do
      {:ok, raw, _key} = Accounts.create_api_key(ctx.user, "k", ctx.access)
      {:ok, _, chan} = sync_join_only(key_socket(raw), ctx.user, ctx.r)
      mon = watch(chan)

      Engram.Auth.SessionInvalidator.disconnect_user(to_string(ctx.user.id))
      refute_receive {:DOWN, ^mon, _, _, _}, 200
    end
  end

  describe "with the broadcast lost" do
    setup :fast_recheck

    test "the periodic re-check stops a sync channel and closes its socket", ctx do
      {:ok, raw, key} = Accounts.create_api_key(ctx.user, "k", ctx.access)
      {:ok, _, chan} = sync_join_only(key_socket(raw), ctx.user, ctx.r)
      topic = "sync:#{ctx.user.id}:#{ctx.r.id}"
      mon = watch(chan)

      narrow_silently(key, ctx.r, "none")
      assert_receive {:DOWN, ^mon, :process, _, {:shutdown, :access_changed}}, 2_000
      # Its own socket (this test process is the transport) is told to close.
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      await_unsubscribed(topic, chan.channel_pid)

      EngramWeb.Endpoint.broadcast!(topic, "note_changed", %{"path" => "secret.md"})
      refute_push "note_changed", %{"path" => "secret.md"}
    end

    test "the periodic re-check stops a crdt channel narrowed to read", ctx do
      {:ok, raw, key} = Accounts.create_api_key(ctx.user, "k", ctx.access)
      {:ok, _, chan} = crdt_join(key_socket(raw), ctx.user, ctx.w)
      mon = watch(chan)

      narrow_silently(key, ctx.w, "read")
      assert_receive {:DOWN, ^mon, :process, _, {:shutdown, :access_changed}}, 2_000
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "a re-check that finds access unchanged keeps the channel open", ctx do
      {:ok, raw, _key} = Accounts.create_api_key(ctx.user, "k", ctx.access)
      {:ok, _, chan} = crdt_join(key_socket(raw), ctx.user, ctx.w)
      mon = watch(chan)

      refute_receive {:DOWN, ^mon, _, _, _}, 300
      refute_received %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
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
