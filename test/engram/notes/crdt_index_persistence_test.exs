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
  index STALE, never silently wrong. Nothing reads the index yet and no rebuild
  path exists; "stale is tolerable" is a statement about today.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]

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

  # The two cases an independent review named as "would have caught the
  # criticals". Both are about NOT writing: a checkpoint that writes when it
  # should not is how the durable snapshot gets destroyed, and there is only one
  # row with no history behind it.
  describe "refusing to checkpoint" do
    test "a snapshot that cannot be decrypted is not overwritten with an empty one", ctx do
      room = start_index_room(ctx)
      put_entry(room, "precious.md", "note-precious")
      stop_room_and_wait(room)

      good = tenant_get(ctx.user, ctx.vault.id)

      # Corrupt the ciphertext in place — the shape of a transient decrypt
      # failure (a DEK cache miss racing a KMS blip) as far as bind/3 can tell.
      <<first, rest::binary>> = good.state_ciphertext

      {:ok, _} =
        Repo.with_tenant(ctx.user.id, fn ->
          Repo.update_all(VaultIndexState,
            set: [state_ciphertext: <<Bitwise.bxor(first, 1), rest::binary>>]
          )
        end)

      corrupted = tenant_get(ctx.user, ctx.vault.id)

      # Fail LOUD: the room must refuse to start rather than come up empty.
      # Coming up empty is what lets the next unbind write nothing over
      # everything.
      assert {:error, _} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)

      # THE assertion: the bytes are still the (corrupt) ones we planted, not an
      # encryption of an empty doc. A transient failure must stay recoverable.
      assert tenant_get(ctx.user, ctx.vault.id).state_ciphertext ==
               corrupted.state_ciphertext
    end

    test "a checkpoint landing mid-DEK-rotation is skipped, not written", ctx do
      room = start_index_room(ctx)
      put_entry(room, "before-rotation.md", "note-before")
      stop_room_and_wait(room)

      before = tenant_get(ctx.user, ctx.vault.id)

      # Rotation in progress. SessionInvalidator.disconnect_user/1 fires at the
      # TOP of a rotation, so rooms drain WHILE the sweep runs — and
      # users.encrypted_dek still holds the old wrapped dek until final_flip,
      # the last phase. A checkpoint in that window encrypts under the old key
      # and lands on a row the sweep has already re-wrapped: unreadable forever
      # once the old key retires. Re-reading the user does not help; only the
      # gate does.
      # Set the column directly: update_user_encryption/2 casts only
      # encrypted_dek/dek_version/key_provider, so it would DROP this silently.
      {1, _} =
        Repo.update_all(
          from(u in Engram.Accounts.User, where: u.id == ^ctx.user.id),
          set: [dek_rotation_locked_at: DateTime.utc_now()]
        )

      respun = start_index_room(ctx)
      put_entry(respun, "during-rotation.md", "note-during")
      stop_room_and_wait(respun)

      assert tenant_get(ctx.user, ctx.vault.id).state_ciphertext == before.state_ciphertext,
             "the checkpoint must be SKIPPED mid-rotation — stale index beats an unreadable one"
    end
  end

  # The documented lossy case, asserted rather than merely described. If someone
  # later adds a tail log, this test is what tells them the trade-off changed.
  describe "ungraceful death" do
    test "a killed room loses writes since the last checkpoint", ctx do
      room = start_index_room(ctx)
      put_entry(room, "saved.md", "note-saved")
      stop_room_and_wait(room)

      respun = start_index_room(ctx)
      put_entry(respun, "unsaved.md", "note-unsaved")

      ref = Process.monitor(respun)
      Process.exit(respun, :kill)
      assert_receive {:DOWN, ^ref, :process, ^respun, :killed}, 5_000

      final = start_index_room(ctx)

      assert read_entry(final, "saved.md")["note_id"] == "note-saved",
             "the last checkpoint must survive"

      refute read_entry(final, "unsaved.md"),
             "snapshot-only: a SIGKILL loses writes since the last exit (add a tail log to change this)"
    end
  end

  # A deploy terminates rooms via the supervisor, not by dropping observers.
  # That path only reaches unbind/3 because bind/3 sets trap_exit — without it
  # the room takes the :shutdown signal and dies unflushed. Nothing else in this
  # suite executes it: delete the Process.flag(:trap_exit, true) line and every
  # other test still passes.
  describe "supervisor shutdown" do
    test "a room terminated by its supervisor still checkpoints", ctx do
      room = start_index_room(ctx)
      put_entry(room, "deploy.md", "note-deploy")

      ref = Process.monitor(room)
      :ok = DynamicSupervisor.terminate_child(Engram.Notes.CrdtDocSupervisor, room)
      assert_receive {:DOWN, ^ref, :process, ^room, _}, 5_000

      assert %VaultIndexState{} = tenant_get(ctx.user, ctx.vault.id),
             "a deploy must flush the index, not drop it"

      respun = start_index_room(ctx)
      assert read_entry(respun, "deploy.md")["note_id"] == "note-deploy"
    end
  end

  # The else-branch of unbind/3 exists to be loud about a failed checkpoint.
  # Nothing executed it, so "loud" was an untested claim.
  describe "checkpoint failure reporting" do
    test "an encrypt failure is counted and logged rather than passing silently", ctx do
      test_pid = self()
      handler = "idx-ckpt-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:engram, :crdt, :index_checkpoint],
        fn _e, m, meta, _ -> send(test_pid, {:ckpt, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      room = start_index_room(ctx)
      put_entry(room, "doomed.md", "note-doomed")

      # Corrupt the wrapped DEK rather than NULLing it: encrypt_index_state/3
      # calls ensure_user_dek/1 first, which would happily PROVISION a fresh DEK
      # for a nil blob and succeed. An unrecognisable blob passes that check
      # (is_binary) and fails at get_dek/1's identify_from_blob instead.
      {1, _} =
        Repo.update_all(
          from(u in Engram.Accounts.User, where: u.id == ^ctx.user.id),
          set: [encrypted_dek: <<0, 1, 2, 3>>]
        )

      Engram.Crypto.DekCache.invalidate(ctx.user.id)

      stop_room_and_wait(room)

      assert_receive {:ckpt, %{count: 1}, %{phase: :failed}}, 2_000
    end

    test "a successful checkpoint is counted", ctx do
      test_pid = self()
      handler = "idx-ok-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:engram, :crdt, :index_checkpoint],
        fn _e, m, meta, _ -> send(test_pid, {:ckpt, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      room = start_index_room(ctx)
      put_entry(room, "fine.md", "note-fine")
      stop_room_and_wait(room)

      assert_receive {:ckpt, %{count: 1}, %{phase: :ok}}, 2_000
    end
  end

  # Projection is what makes the index usable by REST/search/MCP. Wiring it to
  # the checkpoint is the only thing that ever triggers it, so the wiring needs
  # its own assertion — the projection worker's own tests all invoke it directly.
  describe "projection handoff" do
    test "a successful checkpoint enqueues the projection for this vault", ctx do
      room = start_index_room(ctx)
      put_entry(room, "handoff.md", "note-handoff")
      stop_room_and_wait(room)

      assert_enqueued(
        worker: Engram.Workers.ProjectVaultIndex,
        args: %{user_id: ctx.user.id, vault_id: ctx.vault.id}
      )
    end

    test "a skipped checkpoint enqueues nothing", ctx do
      room = start_index_room(ctx)
      put_entry(room, "skipped.md", "note-skipped")

      {1, _} =
        Repo.update_all(
          from(u in Engram.Accounts.User, where: u.id == ^ctx.user.id),
          set: [dek_rotation_locked_at: DateTime.utc_now()]
        )

      stop_room_and_wait(room)

      refute_enqueued(worker: Engram.Workers.ProjectVaultIndex)
    end
  end

  describe "isolation and binding" do
    test "one vault's index never bleeds into another's", ctx do
      {:ok, other} = Vaults.create_vault(ctx.user, %{name: "OtherVault"})

      room = start_index_room(ctx)
      put_entry(room, "mine.md", "note-mine")
      stop_room_and_wait(room)

      other_room = start_index_room(%{user: ctx.user, vault: other})
      put_entry(other_room, "theirs.md", "note-theirs")
      stop_room_and_wait(other_room)

      # BOTH directions. Asserting only "the other room cannot see mine.md"
      # passes against a bind/3 that restores NOTHING — an empty room sees no
      # keys at all. Each room must get its OWN entry back and neither the
      # other's.
      mine = start_index_room(ctx)
      theirs = start_index_room(%{user: ctx.user, vault: other})

      assert read_entry(mine, "mine.md")["note_id"] == "note-mine"
      refute read_entry(mine, "theirs.md")

      assert read_entry(theirs, "theirs.md")["note_id"] == "note-theirs"
      refute read_entry(theirs, "mine.md")
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
