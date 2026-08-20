defmodule Engram.Notes.RestWriteInterleaveTest do
  @moduledoc """
  The REST/MCP note write must not clobber a checkpoint that commits after it
  read the row (#1335). This is the MIRROR of the checkpoint-side interleave:
  the write parks, and a checkpoint commits in the gap.

  ## Why the naive version of this test is worthless

  `Engram.DataCase` checks out one sandbox connection wrapped in a transaction
  that never commits, so nothing can commit into the gap and the race is never
  exercised. #1335 says so explicitly, and the two previous attempts at this bug
  class both shipped tests that passed with the fix reverted.

  `Engram.CheckpointInterleave` fixes both halves: real connections that
  genuinely commit, and a park point that holds the writer still while one of
  them does. `Notes.lookup_and_write/11` calls the hook at `:after_note_read` —
  between the row read and the fenced write, which IS the gap.

  ## Why the fence is on crdt_state and not version

  The checkpoint branch that causes the loss is COMPACTION: it folds the live
  tail ops into a new snapshot, writes `crdt_state_ciphertext`, prunes the tail
  rows, and deliberately leaves `version` and `seq` alone so legacy `/changes`
  pullers see no phantom edit. A version fence cannot see it. `replay_tail` then
  finds the pruned rows gone, the merge silently proceeds from the stale
  snapshot, and the ops are destroyed with no trace on disk.

  So the interleave here commits a COMPACTION, not a content change. A test that
  used a content-changing checkpoint would pass against a version fence and
  prove nothing about the real bug.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Engram.Factory

  alias Engram.CheckpointInterleave
  alias Engram.Crypto
  alias Engram.Notes
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, Note}
  alias Engram.Repo

  setup do
    CheckpointInterleave.checkout_real!()

    # The factory's email sequence restarts at 0 every run, and these rows really
    # commit and outlive the test, so a sequence-derived address collides with a
    # previous run's leftovers. Unique per process AND per wall-clock run.
    email = "rest-interleave-#{System.unique_integer([:positive])}-#{System.os_time()}@test.com"

    # Registered BEFORE the first committing write: if setup raises halfway, a
    # cleanup registered after it would never run and the orphans survive every
    # later run. The id is generated up front so the callback can close over it.
    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user = insert(:user, id: user_id, email: email)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Interleave", Ecto.UUID.generate())

    %{user: user, vault: vault}
  end

  # Deliberately NOT tagged. test_helper.exs excludes :qdrant_integration,
  # :cluster and :integration by default, and a tag here would be one edit away
  # from joining them — an interleave test that silently stops running is worse
  # than no interleave test, which is the exact history #1335 records.
  test "a checkpoint that commits mid-write is not clobbered", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "race.md", "content" => "BODY"})

    # The live room's doc, carrying an edit that exists ONLY there and in the
    # tail log — never yet materialized into notes.content.
    {:ok, live} = CrdtBridge.doc_from_state(nil)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(live, CrdtBridge.text_name()), "BODY LIVE")

    on_exit(CheckpointInterleave.arm(:after_note_read))

    writer =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()
        Notes.upsert_note(user, vault, %{"path" => "race.md", "content" => "BODY REST"})
      end)

    # Blocks until the writer is parked between its row read and its write. If
    # it never parks this raises, so the assertions below cannot pass vacuously.
    parked = CheckpointInterleave.await_parked(:after_note_read, writer.pid)

    # The checkpoint commits IN THE GAP, on a different real connection. It
    # materializes the live edit into notes.content, rewrites crdt_state, and
    # PRUNES the tail — so after this, "LIVE" exists nowhere except the row.
    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, live)

    # The snapshot the checkpoint just committed, captured while the writer is
    # still parked. This is the state the write must not lose.
    cp_raw = Repo.one!(from(n in Note, where: n.id == ^note.id), skip_tenant_check: true)
    {:ok, cp_state} = Crypto.decrypt_crdt_state(cp_raw, user)

    CheckpointInterleave.release(:after_note_read, parked)
    assert {:ok, _} = Task.await(writer, 15_000)

    raw = Repo.one!(from(n in Note, where: n.id == ^note.id), skip_tenant_check: true)
    {:ok, fresh} = Crypto.maybe_decrypt_note_fields(raw, user)

    assert fresh.content =~ "REST",
           "the REST write was lost entirely: #{inspect(fresh.content)}"

    # Text alone CANNOT distinguish the bug. A full-content REST push is
    # authoritative for text, so the projected result converges to "BODY REST"
    # whether the merge used the checkpoint's snapshot as its ancestor or the
    # stale pre-checkpoint one. What differs is the CRDT lineage: an unfenced
    # write persists a snapshot derived from the stale ancestor, so the
    # checkpoint's ops are absent from it — and the tail rows that held them
    # were pruned by the checkpoint, so they exist nowhere on disk.
    #
    # Observe it by asking what the stored state is MISSING relative to the
    # checkpoint's. If the write folded the checkpoint in, replaying those ops
    # is a no-op. If it clobbered them, they come back and the text changes.
    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, stored} = CrdtBridge.doc_from_state(state)
    before_replay = CrdtBridge.text_of(stored)

    {:ok, cp_doc} = CrdtBridge.doc_from_state(cp_state)
    {:ok, sv} = Yex.encode_state_vector(stored)
    {:ok, missing} = Yex.encode_state_as_update(cp_doc, sv)
    :ok = Yex.apply_update(stored, missing)

    assert CrdtBridge.text_of(stored) == before_replay,
           """
           the stored crdt_state did not contain the checkpoint's ops, so
           replaying them changed the doc. The write merged from the
           PRE-checkpoint snapshot and persisted it; the tail rows holding those
           ops were already pruned, so they are unrecoverable.

           stored:        #{inspect(before_replay)}
           after replay:  #{inspect(CrdtBridge.text_of(stored))}
           """
  end
end
