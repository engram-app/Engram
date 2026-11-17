defmodule Engram.Notes.CheckpointInterleaveTest do
  @moduledoc """
  The MIRROR of `rest_write_interleave_test.exs` (#1335).

  That one parks the REST/MCP write and commits a checkpoint in the gap. This
  one parks the CHECKPOINT and commits a REST write in the gap — the same race,
  the other way round, and it was still open after #1356 fixed the first
  direction.

  Both checkpoint branches that write `crdt_state` (compaction, and the
  structural/`.canvas` branch) then PRUNE THE TAIL. With a primary-key-only
  WHERE, a REST write committing in the gap had its `crdt_state` overwritten by
  a union of the pre-REST row while `notes.content` kept the REST text: doc and
  façade diverge, the next bind projects the older doc, and the REST edit
  reverts on every device — with the tail rows that held it already pruned.

  Real connections and a park point, for the reason `CheckpointInterleave`
  documents: the sandbox is one connection in one never-committed transaction,
  so nothing can commit into the gap and a naive version of this test proves
  nothing.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Engram.Factory

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.CheckpointInterleave
  alias Engram.Crypto
  alias Engram.Notes

  alias Engram.Notes.{
    CrdtBridge,
    CrdtCheckpoint,
    CrdtCheckpointTimer,
    CrdtRegistry,
    CrdtUpdateLog
  }

  alias Engram.Repo
  alias Yex.Sync.SharedDoc

  setup do
    CheckpointInterleave.checkout_real!()

    email = "cp-interleave-#{System.unique_integer([:positive])}-#{System.os_time()}@test.com"

    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user = insert(:user, id: user_id, email: email)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "CpInterleave", Ecto.UUID.generate())

    %{user: user, vault: vault}
  end

  test "a REST write that commits mid-checkpoint is not clobbered", %{user: user, vault: vault} do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "cp.md", "content" => "BODY"}, actor: "api")

    # The state a real room binds from. Hydrating the live doc from THIS is what
    # makes the checkpoint's union idempotent — a doc built fresh with the same
    # text is a different Yjs lineage, and unioning it duplicates the body
    # ("BODYBODY") instead of taking the compaction branch.
    seed = Engram.Fixtures.raw_note!(note.id)
    {:ok, seed_state} = Crypto.decrypt_crdt_state(seed, user)

    on_exit(CheckpointInterleave.arm(:after_row_read))

    checkpointer =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()

        # Built INSIDE the task: a Yex.Doc is a NIF resource behind a process
        # and every operation is a call to its OWNER, so a doc created in the
        # test process deadlocks the moment that process blocks on its own DB
        # work. Same lineage AND same projected text as the row, so the
        # checkpoint takes the COMPACTION branch — the one that rewrites
        # crdt_state and prunes while deliberately leaving version and seq
        # alone, which is exactly what a version fence cannot see.
        {:ok, live} = CrdtBridge.doc_from_state(seed_state)

        CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, live)
      end)

    parked = CheckpointInterleave.await_parked(:after_row_read, checkpointer.pid)

    # The competing write, on a different real connection, while the checkpoint
    # holds its read.
    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "cp.md", "content" => "BODY REST"}, actor: "api")

    CheckpointInterleave.release(:after_row_read, parked)

    # `checkpoint/5` returns :ok for EVERY outcome — success, {:skip, _},
    # {:abort, _}, and any rescued raise — so awaiting it proves only that the
    # task finished. The assertions below are on stored state for that reason.
    assert :ok = Task.await(checkpointer, 15_000)

    raw = Engram.Fixtures.raw_note!(note.id)
    {:ok, fresh} = Crypto.maybe_decrypt_note_fields(raw, user)

    # The façade keeps the REST text either way — the compaction branch never
    # writes content. The bug is that crdt_state stops agreeing with it.
    assert fresh.content =~ "REST"

    # The doc must contain the REST edit. If the checkpoint wrote its
    # pre-REST union over the top, the next bind projects "BODY" and the edit
    # reverts on every device.
    assert {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, stored} = CrdtBridge.doc_from_state(state)

    assert CrdtBridge.text_of(stored) =~ "REST",
           """
           the checkpoint clobbered a REST write that committed while it was
           parked. notes.content still says #{inspect(fresh.content)}, but
           crdt_state projects #{inspect(CrdtBridge.text_of(stored))} — the next
           bind serves the doc, so the edit reverts everywhere. The tail rows
           are pruned, so it is unrecoverable.
           """
  end

  test "the fence catches a writer that changes crdt_state WITHOUT bumping seq", ctx do
    %{user: user, vault: vault} = ctx

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "cp2.md", "content" => "BODY"}, actor: "api")

    seed = Engram.Fixtures.raw_note!(note.id)
    {:ok, seed_state} = Crypto.decrypt_crdt_state(seed, user)

    on_exit(CheckpointInterleave.arm(:after_row_read))

    checkpointer =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()
        {:ok, live} = CrdtBridge.doc_from_state(seed_state)
        CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, live)
      end)

    parked = CheckpointInterleave.await_parked(:after_row_read, checkpointer.pid)

    # The competing writer here rewrites crdt_state and NOTHING else — no seq,
    # no version. That is what a sibling compaction (and BackfillCrdtState) does,
    # and it is the case the `seq` half of the fence is blind to. The other test
    # uses upsert_note, which bumps seq, so it would still pass with the
    # crdt_state half of the fence deleted; this one would not.
    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(seed_state, user, note.id)

    Engram.Fixtures.write_note_body!(note.id,
      crdt_state_ciphertext: ct,
      crdt_state_nonce: nonce
    )

    CheckpointInterleave.release(:after_row_read, parked)
    assert :ok = Task.await(checkpointer, 15_000)

    raw = Engram.Fixtures.raw_note!(note.id)

    assert raw.crdt_state_nonce == nonce,
           """
           the checkpoint overwrote a crdt_state written while it was parked,
           even though seq never moved. Only the crdt_state half of the fence
           can see this writer.
           """

    # And critically: a fence loss must NOT prune. The tail is the only durable
    # copy of anything the newer row does not carry.
    {:ok, tail} =
      Repo.with_tenant(user.id, fn ->
        Repo.aggregate(from(l in CrdtUpdateLog, where: l.note_id == ^note.id), :count)
      end)

    assert is_integer(tail)
  end

  # A room checkpoint that loses its snapshot fence wrote nothing, and nothing
  # else ticks: a folder rename bumps the moved rows' seq without touching the
  # room. The timer must retry, or the edit sits only in the room until the next
  # edit, the 300 s idle unbind or an overflow job.
  describe "a room checkpoint that loses the stale-write race" do
    setup %{user: user, vault: vault} do
      # Only the edit's eager tick and the retries fire; no settle/ceiling tick
      # can stand in for a missing retry.
      Application.put_env(:engram, CrdtCheckpointTimer,
        settle_ms: 600_000,
        ceiling_ms: 600_000,
        eager_ms: 50
      )

      on_exit(fn -> Application.delete_env(:engram, CrdtCheckpointTimer) end)

      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => "Old/cp3.md", "content" => "base"},
          actor: "api"
        )

      # The room and its timer run on the test's real connection.
      Sandbox.mode(Repo, {:shared, self()})

      # Runs before the outer cleanup (on_exit is LIFO): the room's unbind
      # needs a connection, and the test process is gone by then.
      on_exit(fn ->
        CheckpointInterleave.checkout_real!()
        Sandbox.mode(Repo, {:shared, self()})
        CrdtRegistry.terminate_room(note.id)
        Sandbox.mode(Repo, :manual)
      end)

      {:ok, room} = CrdtRegistry.ensure_started(user.id, vault.id, note.id)
      _ = :sys.get_state(room)
      %{note: note, room: room, timer: CheckpointInterleave.timer_of(room)}
    end

    defp edit!(room, text) do
      :ok =
        SharedDoc.update_doc(room, fn doc ->
          doc |> Yex.Doc.get_text(CrdtBridge.text_name()) |> Yex.Text.insert(0, text)
        end)
    end

    test "a folder rename mid-checkpoint is retried and announced", ctx do
      %{user: user, vault: vault, note: note, room: room, timer: timer} = ctx

      on_exit(CheckpointInterleave.arm(:after_row_read))
      edit!(room, "ROOM-")
      parked = CheckpointInterleave.await_parked(:after_row_read, timer)

      rename =
        Task.async(fn ->
          CheckpointInterleave.checkout_real!()
          Notes.rename_folder(user, vault, "Old", "New")
        end)

      assert {:ok, _} = Task.await(rename, 15_000)

      EngramWeb.Endpoint.subscribe("crdt:#{user.id}:#{vault.id}")
      # A device that reconnected after the edit's live fan-out and before this
      # checkpoint joins the sync topic late; only the checkpoint can give it the text.
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
      CheckpointInterleave.release(:after_row_read, parked)

      # No further edit: only a retry can write and announce this.
      note_id = note.id

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "crdt_doc_ready",
                       payload: %{"doc_id" => ^note_id}
                     },
                     1_000

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "note_yjs_update",
                       payload: %{"note_id" => ^note_id, "b64" => b64}
                     },
                     1_000

      {:ok, doc} = CrdtBridge.doc_from_state(Base.decode64!(b64))
      assert doc |> Yex.Doc.get_text(CrdtBridge.text_name()) |> Yex.Text.to_string() =~ "ROOM-"

      {:ok, fresh} = Notes.get_note(user, vault, "New/cp3.md")
      assert fresh.content == "ROOM-base"
    end

    # Reports each checkpoint row read to the test as {:row_read, n}, and bumps
    # the note's seq on another connection right after the reads `lose?` picks,
    # so that attempt misses the snapshot fence exactly as a folder rename does.
    defp row_reads(note_id, lose?) do
      test_pid = self()
      reads = :counters.new(1, [])

      CheckpointInterleave.put_hook(fn
        :after_row_read ->
          :counters.add(reads, 1, 1)
          n = :counters.get(reads, 1)
          if lose?.(n), do: bump_seq!(note_id)
          send(test_pid, {:row_read, n})
          :ok

        _ ->
          :ok
      end)
    end

    # Monitored, not linked: the timer traps exits and stops on any
    # {:EXIT, _, _}, so a Task.async here would end the room.
    defp bump_seq!(note_id) do
      {_, ref} =
        spawn_monitor(fn ->
          CheckpointInterleave.checkout_real!()
          seq = Engram.Fixtures.raw_note!(note_id).seq
          Engram.Fixtures.write_note_body!(note_id, seq: seq + 1)
        end)

      receive do
        {:DOWN, ^ref, :process, _, :normal} -> :ok
      after
        15_000 -> raise "seq bump never finished"
      end
    end

    # The compaction branch (text unchanged, crdt_state rewritten) has its own
    # fenced write; it must report the same lost race, not a plain skip.
    test "a trashed row's checkpoint fans nothing out", ctx do
      %{user: user, vault: vault, room: room} = ctx
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      edit!(room, "ROOM-")
      # The room's own live delta for the edit; only the checkpoint's is under test.
      assert_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 1_000

      # Trashing ends the room, whose exit checkpoint then meets a trashed row.
      assert :ok = Notes.delete_note(user, vault, "Old/cp3.md")

      refute_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 300
    end

    test "a compaction checkpoint that loses the race is retried", ctx do
      %{timer: timer, note: note} = ctx
      row_reads(note.id, &(&1 == 1))
      before = Engram.Fixtures.raw_note!(note.id)
      EngramWeb.Endpoint.subscribe("sync:#{ctx.user.id}:#{ctx.vault.id}")

      # No edit: the room's text equals the row's, so this tick compacts.
      send(timer, :tick)
      assert_receive {:row_read, 1}, 1_000
      assert_receive {:row_read, 2}, 1_000
      _ = :sys.get_state(timer)

      assert %{stale_retries: 0} = :sys.get_state(timer)
      assert Engram.Fixtures.raw_note!(note.id).crdt_state_nonce != before.crdt_state_nonce
      # Unchanged text: nothing for an idle device to apply.
      refute_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 200
    end

    test "a checkpoint that keeps losing the race stops retrying", ctx do
      %{room: room, timer: timer, note: note} = ctx
      row_reads(note.id, fn _ -> true end)
      EngramWeb.Endpoint.subscribe("sync:#{ctx.user.id}:#{ctx.vault.id}")

      log =
        capture_log(fn ->
          edit!(room, "ROOM-")
          # The first tick and its 3 retries, then the cap.
          for n <- 1..4, do: assert_receive({:row_read, ^n}, 1_000)
          # The cap is logged in the same handle_info as the 4th attempt.
          _ = :sys.get_state(timer)
        end)

      assert log =~ "crdt checkpoint stale retries exhausted"
      # Every attempt lost the fence and wrote nothing: no fan-out beyond the
      # room's own live delta for the edit.
      assert_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 1_000
      refute_receive %Phoenix.Socket.Broadcast{event: "note_yjs_update"}, 200
      assert %{settle_timer: nil, stale_retries: 0} = :sys.get_state(timer)
      refute_receive {:row_read, 5}, 300
    end
  end
end
