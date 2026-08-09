defmodule Engram.Notes.CrdtCheckpointInterleaveTest do
  @moduledoc """
  The mid-transaction race on the checkpoint write path (#1326, #847, #902).

  `CrdtCheckpoint` reads the note row inside `Repo.with_tenant`, does crypto +
  Yjs work, then writes. At READ COMMITTED a REST/MCP write committing in that
  gap is visible to the UPDATE, so an unfenced checkpoint overwrites it and the
  user's committed edit is gone.

  Every previous attempt to pin this was vacuous, because the ExUnit sandbox
  cannot commit from a second connection — the two prior test attempts on #1325
  both passed for the wrong reason. This uses real connections plus a parked
  interleave point so the race is deterministic rather than hoped for.

  NOT `async` and NOT sandboxed: these writes really commit.
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Engram.CheckpointInterleave
  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, Note}

  setup do
    CheckpointInterleave.checkout_real!()

    # The factory's `sequence(:email, ...)` restarts at 0 every run. These rows
    # really commit and outlive the test, so a sequence-derived address collides
    # with a previous run's leftovers on `users_email_lower_index`. Make it
    # unique per process AND per wall-clock run.
    email = "interleave-#{System.unique_integer([:positive])}-#{System.os_time()}@test.com"

    # Registered BEFORE the first committing write. `insert(:user)` commits on a
    # real connection, so if ensure_user_dek/create_vault/upsert_note then
    # raises, a cleanup registered after them never runs and the orphan rows
    # survive every later run — reproducing the cross-suite failures this
    # module's docstring describes, with nothing pointing back here. The id is
    # generated up front so the callback can close over it.
    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user = insert(:user, id: user_id, email: email)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "InterleaveTest"})
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "before"})

    %{user: user, vault: vault, note: note}
  end

  test "a REST write committing mid-checkpoint is not reverted", ctx do
    %{user: user, vault: vault, note: note} = ctx

    # State for the live room's doc, captured while the row still says "before".
    {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)

    restore = CheckpointInterleave.arm(:after_row_read)
    on_exit(restore)

    # The doc is built INSIDE the task on purpose. A Yex.Doc is backed by a
    # process owned by whoever created it, and `checkpoint/5` encodes the doc
    # before opening its transaction. Built out here, that encode would call
    # back into this test process — which is parked in `await_parked/1` by then
    # — and deadlock until the 5s Yex call timeout.
    #
    # Unbind-shaped call: no :captured_version, exactly as CrdtPersistence does.
    task =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()
        {:ok, doc} = CrdtBridge.doc_from_state(raw_state)

        :ok =
          CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "ROOM EDIT")

        CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)
      end)

    # The checkpoint is now parked INSIDE its transaction, past the row read.
    parked = CheckpointInterleave.await_parked(:after_row_read, task.pid)

    # This commits on a different real connection, in the gap. It is the write
    # the checkpoint has already read past and must not overwrite.
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "p.md", "content" => "REST WINS"})

    CheckpointInterleave.release(:after_row_read, parked)
    assert :ok = Task.await(task, 15_000)

    {:ok, fresh} = Notes.get_note(user, vault, "p.md")

    assert fresh.content =~ "REST WINS",
           """
           checkpoint reverted a REST write that committed mid-transaction.

           This is the #902/#847 loss class: the row was read before the commit,
           the projection was built from that stale read, and the unfenced
           UPDATE wrote it over the newer committed content.

           got: #{inspect(fresh.content)}
           """

    # Asserting only the above would be VACUOUS: a checkpoint that did nothing
    # at all satisfies it just as well — exhausted retry budget, a nil note
    # lookup, or a future refactor that no-ops. `checkpoint/5` always returns
    # `:ok` (including for skips and aborts), so the return value proves nothing
    # either.
    #
    # `upsert_note` merges into crdt_state, so a checkpoint that actually
    # retried and re-unioned must produce text containing BOTH sides. That is
    # the assertion that distinguishes "the fence held and the retry merged"
    # from "the checkpoint silently gave up" — the exact class of vacuous pass
    # the two prior attempts on #1325 died of.
    assert fresh.content =~ "ROOM EDIT",
           """
           the room's ops are missing, so the checkpoint did not converge — it
           lost the fence and then gave up rather than re-unioning against the
           committed write.

           got: #{inspect(fresh.content)}
           """
  end
end
