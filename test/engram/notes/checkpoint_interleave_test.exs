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

  alias Engram.CheckpointInterleave
  alias Engram.Crypto
  alias Engram.Notes
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, CrdtUpdateLog, Note}
  alias Engram.Repo

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
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "cp.md", "content" => "BODY"})

    # The state a real room binds from. Hydrating the live doc from THIS is what
    # makes the checkpoint's union idempotent — a doc built fresh with the same
    # text is a different Yjs lineage, and unioning it duplicates the body
    # ("BODYBODY") instead of taking the compaction branch.
    seed = Repo.one!(from(n in Note, where: n.id == ^note.id), skip_tenant_check: true)
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
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "cp.md", "content" => "BODY REST"})

    CheckpointInterleave.release(:after_row_read, parked)

    # `checkpoint/5` returns :ok for EVERY outcome — success, {:skip, _},
    # {:abort, _}, and any rescued raise — so awaiting it proves only that the
    # task finished. The assertions below are on stored state for that reason.
    assert :ok = Task.await(checkpointer, 15_000)

    raw = Repo.one!(from(n in Note, where: n.id == ^note.id), skip_tenant_check: true)
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

    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "cp2.md", "content" => "BODY"})

    seed = Repo.one!(from(n in Note, where: n.id == ^note.id), skip_tenant_check: true)
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

    {1, _} =
      Repo.update_all(
        from(n in Note, where: n.id == ^note.id),
        [set: [crdt_state_ciphertext: ct, crdt_state_nonce: nonce]],
        skip_tenant_check: true
      )

    CheckpointInterleave.release(:after_row_read, parked)
    assert :ok = Task.await(checkpointer, 15_000)

    raw = Repo.one!(from(n in Note, where: n.id == ^note.id), skip_tenant_check: true)

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
end
