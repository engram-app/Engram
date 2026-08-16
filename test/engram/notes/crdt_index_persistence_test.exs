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

  Snapshot-only is no longer enough. #1150's reasoning — that a lost checkpoint
  interval leaves the index merely STALE because the notes rows stay
  authoritative — died with the map-authority decision
  (`docs/context/crdt-identity-authority.md`). The map IS the identity record
  now, so a claim lost between checkpoints is lost outright, not recoverable
  from the rows. Hence the tail log: every update is appended durably, and a
  checkpoint folds the tail into the snapshot and prunes only what it folded.

      write -> tail (durable immediately)
        -> checkpoint folds + prunes -> snapshot
        -> new room binds from snapshot + replays whatever tail remains

  The two failure modes that matter are pruning too much (a claim vanishes) and
  pruning too little (the tail grows forever); both are pinned below.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]

  alias Engram.{Crypto, Repo, Vaults}
  alias Engram.Notes.{CrdtIndexDoc, CrdtIndexRegistry, VaultIndexState, VaultIndexUpdateLog}
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

  # Wait until `n` tail rows are durable for this vault.
  #
  # `SharedDoc.update_doc/2` returns once the mutation has been applied to the
  # doc, but the resulting update is delivered to the room as a MESSAGE and
  # persisted in `handle_update_v1`. So there is a real window in which the doc
  # has changed and nothing is on disk yet, and killing inside it loses the
  # update no matter what the tail log does. That is inherent — note rooms have
  # the same property — so the tests synchronise on durability rather than
  # pretending the write is atomic with the mutation.
  defp tail_count(user, vault_id) do
    {:ok, count} =
      Repo.with_tenant(user.id, fn ->
        Repo.aggregate(from(l in VaultIndexUpdateLog, where: l.vault_id == ^vault_id), :count)
      end)

    count
  end

  defp await_tail(user, vault_id, n) do
    Enum.reduce_while(1..100, :timeout, fn _, _ ->
      count = tail_count(user, vault_id)

      if count >= n do
        {:halt, :ok}
      else
        Process.sleep(20)
        {:cont, :timeout}
      end
    end)
    |> case do
      :ok -> :ok
      :timeout -> flunk("tail never reached #{n} row(s) for vault #{vault_id}")
    end
  end

  # Kill the room outright: no terminate/2, so no unbind/3 and no checkpoint.
  # This is a deploy replacing an ECS task, a node loss, or an OOM kill.
  defp kill_room_and_wait(room) do
    ref = Process.monitor(room)
    Process.exit(room, :kill)
    assert_receive {:DOWN, ^ref, :process, ^room, :killed}, 5_000
    :ok
  end

  describe "durability across an UNGRACEFUL death" do
    # #1391. Snapshot-only was a sound trade while the `notes` rows were
    # authoritative for paths: losing a checkpoint interval left the index
    # STALE, and the rows still held the truth.
    #
    # #1151 step 2 changed the premise. The map is now authoritative and
    # `ProjectVaultIndex` derives the path columns FROM it, so an interval lost
    # to a SIGKILL drops committed path claims — and the rows then converge
    # BACK to the superseded snapshot on the next projection run. There is no
    # rebuild path in `lib/`.
    test "a claim survives a room that dies without checkpointing", ctx do
      room = start_index_room(ctx)
      before = tail_count(ctx.user, ctx.vault.id)
      put_entry(room, "survives.md", "11111111-1111-4111-8111-111111111111")
      :ok = await_tail(ctx.user, ctx.vault.id, before + 1)

      :ok = kill_room_and_wait(room)

      revived = start_index_room(ctx)

      assert read_entry(revived, "survives.md")["note_id"] ==
               "11111111-1111-4111-8111-111111111111",
             "a committed claim was lost because the room died before checkpointing"

      # Stop it before the test ends. unbind/3 now WRITES (checkpoint + tail
      # prune), so a room still alive at teardown runs those against a sandbox
      # connection whose owner has gone.
      :ok = stop_room_and_wait(revived)
    end

    # The tail must carry updates made AFTER the last checkpoint, not replace
    # what the checkpoint already folded in.
    test "a checkpointed entry and a post-checkpoint entry both survive", ctx do
      room = start_index_room(ctx)
      put_entry(room, "folded.md", "22222222-2222-4222-8222-222222222222")
      :ok = stop_room_and_wait(room)

      room2 = start_index_room(ctx)
      # Baseline AFTER the checkpoint above, because that checkpoint prunes the
      # tail it folded in. Awaiting an absolute count of 1 raced the prune: it
      # could observe the row the checkpoint was still deleting, return early,
      # and kill the room before "tailed.md" was ever appended.
      before = tail_count(ctx.user, ctx.vault.id)
      put_entry(room2, "tailed.md", "33333333-3333-4333-8333-333333333333")
      :ok = await_tail(ctx.user, ctx.vault.id, before + 1)
      :ok = kill_room_and_wait(room2)

      revived = start_index_room(ctx)

      assert read_entry(revived, "folded.md")["note_id"] ==
               "22222222-2222-4222-8222-222222222222"

      assert read_entry(revived, "tailed.md")["note_id"] ==
               "33333333-3333-4333-8333-333333333333"

      :ok = stop_room_and_wait(revived)
    end
  end

  describe "the tail prune contract" do
    # y_ex installs the doc update monitor BEFORE bind/3 runs, so every
    # apply_update inside bind echoes back through update_v1/4. Unsuppressed,
    # binding re-appends the snapshot AND the whole tail it just read: n rows
    # become 2n+1 every restart, each cycle also writing a row the size of the
    # entire index. On a vault whose room keeps dying — the exact case the tail
    # exists for — that is a spiral.
    test "binding does not append the snapshot or the tail back onto the tail", ctx do
      room = start_index_room(ctx)
      before = tail_count(ctx.user, ctx.vault.id)
      put_entry(room, "one.md", "44444444-4444-4444-8444-444444444444")
      :ok = await_tail(ctx.user, ctx.vault.id, before + 1)
      :ok = kill_room_and_wait(room)

      after_first = tail_count(ctx.user, ctx.vault.id)

      # Bind twice more. Each bind replays the tail and, if the echo is not
      # suppressed, re-appends everything it replayed.
      revived = start_index_room(ctx)
      :ok = kill_room_and_wait(revived)
      revived2 = start_index_room(ctx)

      assert tail_count(ctx.user, ctx.vault.id) == after_first,
             "bind re-appended its own replay to the tail"

      :ok = stop_room_and_wait(revived2)
    end

    # The test above only pins the UNDER-count direction: it never checkpoints,
    # so `snapshot_applied` is always false, and it issues no update after a
    # bind. An implementation that credited too MANY echoes passed it — and an
    # over-credit is not a cosmetic error, it is a permanent credit that the
    # next real client claim spends instead of being written.
    #
    # yrs fires the update observer from the transaction commit hook only when
    # the transaction CHANGED the doc, so any apply that changes nothing emits
    # nothing. Two ordinary situations produce one:
    #
    #   1. an empty snapshot — a room that bound and exited without a write
    #   2. a tail row a roomless write already folded into the snapshot
    #
    # Both are exercised below. The shape is the same in each: get the room into
    # the suspect state, then write ONE claim and demand exactly one tail row.
    test "a bind over an EMPTY snapshot still appends the next claim", ctx do
      # A room that binds and exits with no writes checkpoints an empty doc.
      ctx |> start_index_room() |> stop_room_and_wait()

      {:ok, snapshot_row} =
        Repo.with_tenant(ctx.user.id, fn ->
          Repo.get_by(VaultIndexState, vault_id: ctx.vault.id)
        end)

      assert %VaultIndexState{} = snapshot_row, "expected an empty snapshot to have been written"
      assert tail_count(ctx.user, ctx.vault.id) == 0

      # Binding applies that empty snapshot: :ok, but no echo.
      room = start_index_room(ctx)
      put_entry(room, "after-empty.md", "66666666-6666-4666-8666-666666666666")

      :ok = await_tail(ctx.user, ctx.vault.id, 1)

      assert tail_count(ctx.user, ctx.vault.id) == 1,
             "the empty snapshot was counted as an echo and swallowed a real claim"

      :ok = stop_room_and_wait(room)
    end

    test "a bind over a NON-EMPTY snapshot appends the next claim exactly once", ctx do
      room = start_index_room(ctx)
      put_entry(room, "snapshotted.md", "77777777-7777-4777-8777-777777777777")
      :ok = await_tail(ctx.user, ctx.vault.id, 1)
      # Graceful: folds into the snapshot and prunes the tail to 0.
      :ok = stop_room_and_wait(room)
      assert tail_count(ctx.user, ctx.vault.id) == 0

      revived = start_index_room(ctx)
      put_entry(revived, "next.md", "88888888-8888-4888-8888-888888888888")
      :ok = await_tail(ctx.user, ctx.vault.id, 1)

      assert tail_count(ctx.user, ctx.vault.id) == 1,
             "the claim after a bind was swallowed by a mis-credited echo"

      :ok = stop_room_and_wait(revived)
    end

    # Sequence B's root cause. `Identity`'s roomless path folds the tail into
    # the snapshot it writes; if it does not also PRUNE, those rows survive and
    # the next bind replays them as no-ops — each one a mis-credited echo, so N
    # leftover rows silently eat the next N claims.
    test "a roomless write prunes the tail rows it folded in", ctx do
      room = start_index_room(ctx)
      put_entry(room, "orphaned.md", "99999999-9999-4999-8999-999999999999")
      :ok = await_tail(ctx.user, ctx.vault.id, 1)
      # Ungraceful: the row survives with no snapshot behind it.
      :ok = kill_room_and_wait(room)
      assert tail_count(ctx.user, ctx.vault.id) == 1

      # No room is live, so this takes Identity's snapshot route.
      assert :ok =
               Engram.Notes.Identity.claim(
                 ctx.user,
                 ctx.vault.id,
                 [{"roomless.md", "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}]
               )

      assert tail_count(ctx.user, ctx.vault.id) == 0,
             "the roomless write folded the tail into its snapshot but left the rows behind"

      # And the folded claim is still there, i.e. it pruned what it folded, not
      # more than it folded.
      revived = start_index_room(ctx)

      assert read_entry(revived, "orphaned.md")["note_id"] ==
               "99999999-9999-4999-8999-999999999999"

      assert read_entry(revived, "roomless.md")["note_id"] ==
               "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

      :ok = stop_room_and_wait(revived)
    end

    test "a checkpoint prunes the tail it folded in", ctx do
      room = start_index_room(ctx)
      before = tail_count(ctx.user, ctx.vault.id)
      put_entry(room, "folded.md", "55555555-5555-4555-8555-555555555555")
      :ok = await_tail(ctx.user, ctx.vault.id, before + 1)

      # Graceful exit -> unbind -> checkpoint -> prune.
      :ok = stop_room_and_wait(room)

      assert tail_count(ctx.user, ctx.vault.id) == 0,
             "a checkpoint left behind rows it had already folded into the snapshot"
    end

    # THE regression for the prune contract. `replay_tail` skips a row it cannot
    # decrypt so a later successful replay can still recover the claim — but the
    # prune used to re-query EVERY row for the vault and delete it anyway. One
    # transient decrypt failure then destroyed the claim permanently, in the
    # code whose entire purpose is preventing that.
    test "a row that could not be replayed is NOT pruned by the checkpoint", ctx do
      room = start_index_room(ctx)
      before = tail_count(ctx.user, ctx.vault.id)
      put_entry(room, "fragile.md", "66666666-6666-4666-8666-666666666666")
      :ok = await_tail(ctx.user, ctx.vault.id, before + 1)
      :ok = kill_room_and_wait(room)

      # Corrupt the ciphertext so replay must skip it, by flipping a bit in the
      # AEAD TAG. Replacing it with a short blob instead would trip
      # Envelope.decrypt/4's `byte_size - 16 < 0` length short-circuit and never
      # reach AES-GCM — still an error, but not the one a real transient or a
      # torn write produces.
      {:ok, [row]} =
        Repo.with_tenant(ctx.user.id, fn ->
          Repo.all(from(l in VaultIndexUpdateLog, where: l.vault_id == ^ctx.vault.id))
        end)

      <<head::binary-size(byte_size(row.update_ciphertext) - 1), last>> = row.update_ciphertext

      {:ok, {1, _}} =
        Repo.with_tenant(ctx.user.id, fn ->
          Repo.update_all(
            from(l in VaultIndexUpdateLog, where: l.id == ^row.id),
            set: [update_ciphertext: <<head::binary, Bitwise.bxor(last, 0xFF)>>]
          )
        end)

      # Bind (skips the row), then check point on the way out.
      revived = start_index_room(ctx)
      :ok = stop_room_and_wait(revived)

      assert tail_count(ctx.user, ctx.vault.id) == 1,
             "the checkpoint deleted a row it never folded in — that claim is now unrecoverable"
    end
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
    # DELETED: "a killed room loses writes since the last checkpoint" (#1391).
    #
    # It asserted `refute read_entry(final, "unsaved.md")` — that a SIGKILL
    # destroys everything since the last checkpoint. That was the correct
    # contract when the room was snapshot-only, and the tail log inverts it:
    # "a claim survives a room that dies without checkpointing", above, now
    # asserts the opposite of it on purpose.
    #
    # It was also passing for the wrong reason. `handle_update_v1` is
    # asynchronous, so the test only stayed green by KILLING the room before
    # the tail append it was meant to disprove had run — a race it happened to
    # win. Keeping it would have meant an intermittently red suite asserting
    # behaviour the design deliberately removed.
    #
    # The residual window it half-described is real (a write killed before it
    # reaches the tail IS lost) and is documented on `await_tail/3`. It is not
    # re-tested here: pinning it requires winning that same race.
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
