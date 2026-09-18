defmodule Engram.Workers.ReindexKeywordRlsTest do
  @moduledoc """
  Pins the per-vault keyword re-normalizer against an ENFORCED row-level
  security policy.

  ## What breaks

  `perform/1` selects the vault's notes from `notes` with no tenant in force.
  Filtered, `note_ids` is `[]` — and every step after it is a well-behaved
  no-op on an empty list:

    * `Indexing.flag_notes_for_rebuild([])` clears nothing and returns 0
    * `EmbedNote.reject_already_queued([], _)` enqueues nothing
    * the log line reports `total_count: 0`

  So the worker returns `:ok`, Oban records a success, and the operator's log
  says it flagged zero notes — which reads exactly like "this vault had nothing
  to do" rather than "the read was filtered". An operator-triggered
  re-normalize that silently does nothing is the worst shape for this job in
  particular: its whole purpose is to repair BM25 weights that are already
  wrong, and it is `unique` per vault for an hour, so a retry inside that
  window is swallowed too.

  ## Why this one needed a job-args change

  The args carried only `vault_id`, and nothing in the worker can derive the
  owner: the `vaults` lookup that would supply it is under the same policy. So
  `user_id` is now part of the args and `enqueue/2` takes it. A legacy job
  holding only `vault_id` cannot be repaired at runtime for the same reason, so
  it is discarded loudly rather than run unscoped — the operator re-triggers.

  ## Harness notes

  The COMMITTING harness is required: the observable is the `EmbedNote` rows
  this job inserts, and a rollback would discard them and pass against a
  completely unscoped implementation.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Workers.EmbedNote
  alias Engram.Workers.ReindexKeyword

  setup do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    note_a = insert(:note, user: user, vault: vault)
    note_b = insert(:note, user: user, vault: vault)

    %{user: user, vault: vault, note_a: note_a, note_b: note_b}
  end

  describe "perform/1 under enforced RLS" do
    # CONTROL. Without it a green file cannot distinguish "correctly scoped"
    # from "the role drop never engaged".
    test "control: the dropped role sees none of the vault's notes", %{vault: vault} do
      assert {:returned, 0} =
               as_prod_role(fn ->
                 Repo.one(
                   from(n in Note, where: n.vault_id == ^vault.id, select: count(n.id)),
                   skip_tenant_check: true
                 )
               end)
    end

    test "re-enqueues the vault's notes instead of silently flagging none",
         %{user: user, vault: vault, note_a: note_a, note_b: note_b} do
      assert :ok =
               as_prod_role_committing(fn ->
                 perform_job(ReindexKeyword, %{
                   "user_id" => user.id,
                   "vault_id" => to_string(vault.id)
                 })
               end)

      # Unscoped, `note_ids` is [] and every later step no-ops on the empty
      # list, so the job reports success having re-normalized nothing.
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => note_a.id})
      assert_enqueued(worker: EmbedNote, args: %{"note_id" => note_b.id})
    end
  end
end
