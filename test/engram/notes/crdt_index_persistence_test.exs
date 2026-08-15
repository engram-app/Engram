defmodule Engram.Notes.CrdtIndexPersistenceTest do
  @moduledoc """
  Durability for the per-vault index room (#1151, step 1 of #1146).

  #1150 shipped the room deliberately memory-only: `bind/3` was a no-op and
  nothing wrote anything, so when the room exited its `filemeta_v0` map was
  simply gone. That is why the index room must NOT opt into the #1152 idle
  drain — draining a NOTE room is lossless only because
  `CrdtPersistence.unbind/3` checkpoints it on the way out.

  These tests pin the round trip that removes that restriction:

      write to the map -> room exits -> encrypted snapshot in the DB
        -> new room binds -> the same entries are back

  Snapshot-only by design (no per-update tail log): index writes are
  rename/create/delete, not keystrokes, and until Engram-obsidian#363 the notes
  rows remain authoritative for paths — so a lost checkpoint interval leaves the
  index STALE and reconstructible, never silently wrong.
  """
  use Engram.DataCase, async: false

  alias Engram.{Crypto, Repo, Vaults}
  alias Engram.Notes.{CrdtIndexDoc, CrdtIndexRegistry, VaultIndexState}
  alias Yex.Sync.SharedDoc

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "IndexPersistenceTest"})

    %{user: user, vault: vault}
  end

  # Start the room the way the channel does, observe it from the test process so
  # `auto_exit` has a last observer to lose, and hand back the pid.
  defp start_index_room(%{user: user, vault: vault}) do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(user.id, vault.id)
    room
  end

  defp put_entry(room, path, note_id) do
    :ok =
      SharedDoc.update_doc(room, fn doc ->
        doc
        |> Yex.Doc.get_map(CrdtIndexDoc.map_name())
        |> Yex.Map.set(path, %{"note_id" => note_id})
      end)
  end

  # `update_doc/2` returns :ok and DISCARDS the function's value, so the read has
  # to be posted back out of the room process rather than returned.
  defp read_entry(room, path) do
    test_pid = self()

    :ok =
      SharedDoc.update_doc(room, fn doc ->
        result = doc |> Yex.Doc.get_map(CrdtIndexDoc.map_name()) |> Yex.Map.fetch(path)
        send(test_pid, {:index_read, path, result})
      end)

    receive do
      {:index_read, ^path, {:ok, value}} -> value
      {:index_read, ^path, :error} -> nil
    after
      2_000 -> flunk("the room never answered a read of #{inspect(path)}")
    end
  end

  # `vault_index_states` is in Repo.@tenant_tables, so a bare read raises
  # Engram.TenantError. That guard is the point — an unguarded query would meet
  # RLS with no `app.current_tenant` and quietly return nothing.
  # NOTE with_tenant/2 runs a TRANSACTION, so it answers {:ok, value}.
  defp tenant_get(user, vault_id) do
    {:ok, row} =
      Repo.with_tenant(user.id, fn -> Repo.get_by(VaultIndexState, vault_id: vault_id) end)

    row
  end

  # Drop the last observer and wait for auto_exit -> terminate/2 -> unbind/3.
  defp stop_room_and_wait(room) do
    ref = Process.monitor(room)
    :ok = SharedDoc.unobserve(room)
    assert_receive {:DOWN, ^ref, :process, ^room, _}, 5_000
    :ok
  end

  describe "snapshot round trip" do
    test "entries written before the room exits are there when it comes back", ctx do
      room = start_index_room(ctx)
      put_entry(room, "Notes/alpha.md", "note-alpha")
      put_entry(room, "Notes/beta.md", "note-beta")
      stop_room_and_wait(room)

      respun = start_index_room(ctx)
      refute respun == room, "sanity: this must be a genuinely new room process"

      assert read_entry(respun, "Notes/alpha.md")["note_id"] == "note-alpha"
      assert read_entry(respun, "Notes/beta.md")["note_id"] == "note-beta"
    end

    test "the snapshot is stored encrypted, never as readable Yjs bytes", ctx do
      room = start_index_room(ctx)
      put_entry(room, "Secret/plans.md", "note-secret")
      stop_room_and_wait(room)

      state = tenant_get(ctx.user, ctx.vault.id)

      assert %VaultIndexState{} = state, "unbind/3 must persist a row"
      assert is_binary(state.state_ciphertext)
      assert is_binary(state.state_nonce)

      # The path is the sensitive part: a Y.Map key is stored verbatim inside a
      # Yjs update, so an unencrypted snapshot would leak every path in the
      # vault to anyone with a DB read.
      refute state.state_ciphertext =~ "Secret/plans.md"
    end

    test "a second checkpoint replaces the snapshot rather than accumulating rows", ctx do
      room = start_index_room(ctx)
      put_entry(room, "one.md", "note-one")
      stop_room_and_wait(room)

      respun = start_index_room(ctx)
      put_entry(respun, "two.md", "note-two")
      stop_room_and_wait(respun)

      {:ok, count} =
        Repo.with_tenant(ctx.user.id, fn ->
          Repo.aggregate(VaultIndexState, :count, :vault_id)
        end)

      assert count == 1,
             "snapshot-only means ONE row per vault, upserted"

      final = start_index_room(ctx)
      assert read_entry(final, "one.md")["note_id"] == "note-one", "earlier entry must survive"
      assert read_entry(final, "two.md")["note_id"] == "note-two"
    end
  end

  describe "isolation and binding" do
    test "one vault's index never bleeds into another's", ctx do
      {:ok, other} = Vaults.create_vault(ctx.user, %{name: "OtherVault"})

      room = start_index_room(ctx)
      put_entry(room, "mine.md", "note-mine")
      stop_room_and_wait(room)

      other_room = start_index_room(%{user: ctx.user, vault: other})

      assert read_entry(other_room, "mine.md") == nil,
             "the index is per-vault; a shared snapshot would cross tenants"
    end

    # Same AAD discipline as notes.crdt_state: the ciphertext is bound to the row
    # it lives in, so a blob moved between vaults fails to decrypt rather than
    # silently handing one vault another's index.
    test "a snapshot moved to another vault's row will not decrypt", ctx do
      {:ok, other} = Vaults.create_vault(ctx.user, %{name: "AadVault"})

      room = start_index_room(ctx)
      put_entry(room, "bound.md", "note-bound")
      stop_room_and_wait(room)

      assert %VaultIndexState{} = stolen = tenant_get(ctx.user, ctx.vault.id)

      forged = %{stolen | vault_id: other.id}

      assert {:error, _} = Crypto.decrypt_index_state(forged, ctx.user)
    end
  end
end
