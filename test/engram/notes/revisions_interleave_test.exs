defmodule Engram.Notes.RevisionsInterleaveTest do
  @moduledoc """
  Review focus #1 for #1710: a LOSING fenced write must record no history.

  The REST/MCP write parks after reading the row; a content-changing checkpoint
  commits in the gap; the write resumes, loses its snapshot fence, and retries
  INSIDE the same transaction (#1335). A history step placed before the fenced
  write would persist a version from the losing attempt, a duplicate baseline
  of stale text. The step must run only after a write that succeeded.

  Real connections (Engram.CheckpointInterleave): the sandbox serializes all
  work onto one connection, so nothing could commit into the gap.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Engram.Factory

  alias Engram.{CheckpointInterleave, Crypto, Notes, Repo}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, Note, Revision, Revisions}

  setup do
    CheckpointInterleave.checkout_real!()
    email = "rev-interleave-#{System.unique_integer([:positive])}-#{System.os_time()}@test.com"
    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user = insert(:user, id: user_id, email: email)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "RevInterleave", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "a write that loses its fence and retries records one clean chain",
       %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "race.md", "content" => "BODY"})

    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, user)
    {:ok, live} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(live, CrdtBridge.text_name()), "BODY LIVE")

    on_exit(CheckpointInterleave.arm(:after_note_read))

    writer =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()

        Notes.upsert_note(user, vault, %{"path" => "race.md", "content" => "BODY REST"},
          actor: "mcp"
        )
      end)

    parked = CheckpointInterleave.await_parked(:after_note_read, writer.pid)
    :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, live)
    CheckpointInterleave.release(:after_note_read, parked)
    assert {:ok, _} = Task.await(writer, 15_000)

    revs = Repo.all(from(r in Revision, where: r.note_id == ^note.id), skip_tenant_check: true)

    assert Enum.count(revs, &is_nil(&1.closed_at)) == 1

    assert Enum.count(revs, &(&1.origin == "baseline")) == 1,
           "the losing attempt left a second baseline: #{inspect(Enum.map(revs, & &1.origin))}"

    baseline = Enum.find(revs, &(&1.origin == "baseline"))
    sync = Enum.find(revs, &(&1.actor == "sync"))
    assert {:ok, "BODY"} = Revisions.decrypt_pending(baseline, user)
    assert {:ok, "BODY LIVE"} = Revisions.decrypt_pending(sync, user)
    assert %Revision{actor: "mcp", closed_at: nil} = Enum.find(revs, &is_nil(&1.closed_at))
  end
end
