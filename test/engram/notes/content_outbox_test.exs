defmodule Engram.Notes.ContentOutboxTest do
  @moduledoc """
  R6 outbox: every content write inserts its `NoteCommitted` job INSIDE its
  own transaction, so the job commits or rolls back with the write. Before,
  the checkpoint and the genesis body inserted it after the commit
  (`Repo.after_commit`), and a crash, a pool timeout or a raise in the
  post-commit work in between lost it; only the 5-minute reconcile sweep
  found the note again. With the sweep every 3 h that gap would be hours.

  `Repo.transaction_after_commit/1` is the seam: it owns the after-commit
  queue, so a job still deferred to "after the commit" is not in the table
  while the block runs, and one written in the write's transaction is.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Crypto.Envelope
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, CrdtUpdateLog, Note, NoteBody}
  alias Engram.Workers.{EmbedNote, NoteCommitted}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "Outbox", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp committed(note_id), do: all_enqueued(worker: NoteCommitted, args: %{note_id: note_id})

  defp doc_with(text) do
    {:ok, doc} = CrdtBridge.doc_from_state(nil)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), text)
    doc
  end

  defp checkpoint_text(u, v, note_id, text) do
    {:ok, raw} = Repo.with_tenant(u.id, fn -> Engram.Fixtures.raw_note!(note_id) end)
    {:ok, state} = Crypto.decrypt_crdt_state(raw, u)
    {:ok, doc} = CrdtBridge.doc_from_state(state)
    :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), text)
    CrdtCheckpoint.checkpoint(u.id, v.id, note_id, doc)
  end

  defp put_hook(fun), do: Engram.CheckpointInterleave.put_hook(fun)

  describe "CRDT checkpoint" do
    setup %{user: u, vault: v} do
      {:ok, note} =
        Notes.upsert_note(u, v, %{"path" => "c.md", "content" => "before"}, actor: "api")

      Repo.delete_all(Oban.Job)
      %{note: note}
    end

    test "the job is in the table before the write's transaction ends",
         %{user: u, vault: v, note: note} do
      {:ok, seen} =
        Repo.transaction_after_commit(fn ->
          :ok = checkpoint_text(u, v, note.id, "after")
          committed(note.id)
        end)

      assert [_] = seen
    end

    # The post-commit work (name index, announce) ran first in the deferred
    # fun, so a raise there lost the job with the write already durable.
    test "a raise in the post-commit work still leaves the job", %{user: u, vault: v, note: note} do
      put_hook(fn
        :post_commit -> raise "post-commit boom"
        _ -> :ok
      end)

      ExUnit.CaptureLog.capture_log(fn -> :ok = checkpoint_text(u, v, note.id, "after") end)
      assert [_] = committed(note.id)
    end

    test "a write that rolls back leaves no job", %{user: u, vault: v, note: note} do
      {:error, :abort} =
        Repo.transaction_after_commit(fn ->
          :ok = checkpoint_text(u, v, note.id, "after")
          Repo.rollback(:abort)
        end)

      assert committed(note.id) == []
    end

    test "a checkpoint that changes no content queues nothing", %{user: u, vault: v, note: note} do
      :ok = checkpoint_text(u, v, note.id, "before")
      assert committed(note.id) == []
    end
  end

  # Review M3: #1710 took the job insert out from under the vault seq lock
  # (`Vaults.next_seq!/1` row-locks the vault to the commit). The outbox
  # insert must come before that bump, still inside the transaction.
  defp outbox_before_seq_bump?(fun) do
    {_, recorded} = Engram.QueryRecorder.record(fun)
    sqls = Enum.map(recorded, & &1.sql)
    insert = Enum.find_index(sqls, &(&1 =~ ~r/INSERT INTO "public"."oban_jobs"/))
    bump = Enum.find_index(sqls, &(&1 =~ "change_seq = change_seq + 1"))
    assert insert && bump, "expected both an outbox insert and a seq bump"
    insert < bump
  end

  describe "the outbox insert is not under the vault seq lock" do
    test "checkpoint", %{user: u, vault: v} do
      {:ok, note} =
        Notes.upsert_note(u, v, %{"path" => "l.md", "content" => "before"}, actor: "api")

      assert outbox_before_seq_bump?(fn -> :ok = checkpoint_text(u, v, note.id, "after") end)
    end

    test "genesis body", %{user: u, vault: v} do
      assert outbox_before_seq_bump?(fn ->
               {:ok, _} =
                 Notes.genesis_crdt_note(u, v, Ecto.UUID.generate(), "lg.md",
                   body: doc_with("genesis body")
                 )
             end)
    end
  end

  describe "genesis body" do
    test "the job is in the table before the create's transaction ends", %{user: u, vault: v} do
      id = Ecto.UUID.generate()

      {:ok, seen} =
        Repo.transaction_after_commit(fn ->
          {:ok, _} = Notes.genesis_crdt_note(u, v, id, "g.md", body: doc_with("genesis body"))
          committed(id)
        end)

      assert [_] = seen
    end

    # R6 missed-18: a bare row whose body never lands (dropped crdt_msg, an
    # empty note) only ever sees compacting checkpoints, so without its own
    # job nothing indexes it and the reconcile sweep reports it missed.
    test "a bare genesis queues one job", %{user: u, vault: v} do
      id = Ecto.UUID.generate()
      {:ok, _} = Notes.genesis_crdt_note(u, v, id, "bare.md")
      assert [_] = committed(id)
    end

    test "a genesis with an empty body queues one job", %{user: u, vault: v} do
      id = Ecto.UUID.generate()
      {:ok, _} = Notes.genesis_crdt_note(u, v, id, "empty.md", body: doc_with(""))
      assert [_] = committed(id)
    end

    test "a bare genesis's job is not under the vault seq lock", %{user: u, vault: v} do
      assert outbox_before_seq_bump?(fn ->
               {:ok, _} = Notes.genesis_crdt_note(u, v, Ecto.UUID.generate(), "lb.md")
             end)
    end
  end

  # R6 missed-18 candidate B: a live relocate folds the uncheckpointed tail
  # into the stored content. The room's next checkpoint then sees no change
  # and compacts, so the relocate itself owes the job.
  describe "a live note relocated by id" do
    # Appends `text` as an uncheckpointed tail update over the row's snapshot.
    defp tail_edit!(u, v, note_id, text) do
      {:ok, raw} = Repo.with_tenant(u.id, fn -> Engram.Fixtures.raw_note!(note_id) end)
      {:ok, state} = Crypto.decrypt_crdt_state(raw, u)
      {:ok, doc} = CrdtBridge.doc_from_state(state)
      :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), text)
      {:ok, update} = Yex.encode_state_as_update(doc)
      insert_tail!(u, v, note_id, update, note_id)
    end

    # A tail row for `note_id`, encrypted under `aad_id`'s AAD (another id
    # makes a row that will not decrypt).
    defp insert_tail!(u, v, note_id, update, aad_id) do
      {:ok, dek} = Crypto.get_dek(u)
      {ct, nonce} = Envelope.encrypt(update, dek, Crypto.aad_for_row(:notes, :crdt_state, aad_id))

      {:ok, _} =
        Repo.with_tenant(u.id, fn ->
          Repo.insert!(%CrdtUpdateLog{
            note_id: note_id,
            user_id: u.id,
            vault_id: v.id,
            update_ciphertext: ct,
            update_nonce: nonce,
            inserted_at: DateTime.utc_now()
          })
        end)

      :ok
    end

    defp drop_snapshot!(u, note_id) do
      {:ok, _} =
        Repo.with_tenant(u.id, fn ->
          Engram.Fixtures.write_note_body!(note_id,
            crdt_state_ciphertext: nil,
            crdt_state_nonce: nil
          )

          # As every app writer: the body row too, with the values written
          # (a copy from `notes` never NULLs a body).
          NoteBody.put!({note_id, crdt_state_ciphertext: nil, crdt_state_nonce: nil})
        end)

      :ok
    end

    defp stored(u, note_id) do
      {:ok, raw} = Repo.with_tenant(u.id, fn -> Engram.Fixtures.raw_note!(note_id) end)
      {:ok, note} = Crypto.maybe_decrypt_note_fields(raw, u)
      note
    end

    test "a relocate that folds a tail edit in queues one job", %{user: u, vault: v} do
      id = Ecto.UUID.generate()
      {:ok, _} = Notes.genesis_crdt_note(u, v, id, "a.md", body: doc_with("before"))
      Repo.delete_all(Oban.Job)
      :ok = tail_edit!(u, v, id, "after")

      {:ok, _} = Notes.genesis_crdt_note(u, v, id, "b.md")

      assert stored(u, id).content == "after"
      assert [_] = committed(id)
    end

    test "a pure relocate queues nothing", %{user: u, vault: v} do
      id = Ecto.UUID.generate()
      {:ok, _} = Notes.genesis_crdt_note(u, v, id, "a.md", body: doc_with("same"))
      Repo.delete_all(Oban.Job)

      {:ok, _} = Notes.genesis_crdt_note(u, v, id, "b.md")

      assert committed(id) == []
    end

    # Data-loss guard: a bare row's snapshot projects "", and its body lives
    # only in the tail. The relocate must keep that body, not diff the empty
    # facade into the tail-inclusive doc and delete it.
    test "a bare row's tail-only body survives a relocate", %{user: u, vault: v} do
      id = Ecto.UUID.generate()
      {:ok, _} = Notes.genesis_crdt_note(u, v, id, "a.md")
      :ok = tail_edit!(u, v, id, "only in the tail")
      Repo.delete_all(Oban.Job)

      {:ok, _} = Notes.genesis_crdt_note(u, v, id, "b.md")

      assert stored(u, id).content == "only in the tail"
      assert [_] = committed(id)
    end

    # Review finding 1: a pre-CRDT row (no snapshot) whose tail holds the bind
    # seed plus a keystroke. The relocate passes the stored "X" back, which
    # must not diff the keystroke away.
    test "a pre-CRDT row's tail edit survives a relocate", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "p.md", "content" => "X"}, actor: "api")
      :ok = drop_snapshot!(u, note.id)
      # One tail update standing for the bind seed "X" plus the keystroke "Y".
      :ok = tail_edit!(u, v, note.id, "XY")

      {:ok, _} = Notes.genesis_crdt_note(u, v, note.id, "q.md")

      assert stored(u, note.id).content == "XY"
    end

    # Delta D1: a canvas keeps its board in Y.Maps, so its text projection is
    # "". Taking the tail doc as the relocate target stored "" over the board.
    test "a canvas with a tail edit keeps its content on relocate", %{user: u, vault: v} do
      body = ~s({"nodes":[{"id":"n1","text":"hi"}],"edges":[]})

      {:ok, note} =
        Notes.upsert_note(u, v, %{"path" => "b.canvas", "content" => body}, actor: "api")

      {:ok, doc} = CrdtBridge.doc_from_state(nil)
      Yex.Map.set(Yex.Doc.get_map(doc, "nodes"), "n0", "base")
      {:ok, state} = Yex.encode_state_as_update(doc)
      {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(state, u, note.id)

      {:ok, _} =
        Repo.with_tenant(u.id, fn ->
          Engram.Fixtures.write_note_body!(note.id,
            crdt_state_ciphertext: ct,
            crdt_state_nonce: nonce
          )

          NoteBody.sync!(note.id, [:crdt_state_ciphertext])
        end)

      Yex.Map.set(Yex.Doc.get_map(doc, "nodes"), "n1", "hi")
      {:ok, update} = Yex.encode_state_as_update(doc)
      :ok = insert_tail!(u, v, note.id, update, note.id)

      {:ok, _} = Notes.genesis_crdt_note(u, v, note.id, "c.canvas")

      assert stored(u, note.id).content == body
    end

    # Delta D2, the feed's two refusals (`trust_projection?/5`) apply to a
    # move too. A tail row that will not decrypt leaves a truncated replay:
    # the stored body wins.
    test "a partial tail replay keeps the stored body", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "t.md", "content" => "X"}, actor: "api")
      :ok = drop_snapshot!(u, note.id)
      :ok = tail_edit!(u, v, note.id, "XY")
      # Encrypted under another row's AAD: replay logs and skips it.
      :ok = insert_tail!(u, v, note.id, "junk", Ecto.UUID.generate())

      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _} = Notes.genesis_crdt_note(u, v, note.id, "t2.md")
      end)

      assert stored(u, note.id).content == "X"
    end

    test "an empty projection over a stored body keeps the body", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "e.md", "content" => "X"}, actor: "api")
      :ok = drop_snapshot!(u, note.id)
      :ok = tail_edit!(u, v, note.id, "")

      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _} = Notes.genesis_crdt_note(u, v, note.id, "e2.md")
      end)

      assert stored(u, note.id).content == "X"
    end

    # Guard: with no tail there is nothing to keep, and the stored text stays.
    test "a pre-CRDT row with no tail keeps its content", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "n.md", "content" => "X"}, actor: "api")
      :ok = drop_snapshot!(u, note.id)

      {:ok, _} = Notes.genesis_crdt_note(u, v, note.id, "m.md")

      assert stored(u, note.id).content == "X"
    end
  end

  # Delta review D2/D3: a job written ahead of a write follows the row the
  # write really made, and is deleted when the write made none.
  describe "a job written ahead of the write" do
    # Runs `fun` once, at the bare insert's seam, inside its transaction.
    defp once_before_insert(fun) do
      put_hook(fn
        :before_bare_insert ->
          if Process.put(:outbox_hook_ran, true) != true, do: fun.()

        _ ->
          :ok
      end)
    end

    test "a create re-minted under a fresh id queues its job under that id",
         %{user: u, vault: v} do
      id = Ecto.UUID.generate()
      {:ok, other, _} = Vaults.register_vault(u, "Other", Ecto.UUID.generate())
      once_before_insert(fn -> insert(:note, id: id, user: u, vault: other, path: "x.md") end)

      {:ok, note} = Notes.genesis_crdt_note(u, v, id, "remint.md", body: doc_with("body"))

      assert note.id != id
      assert [_] = committed(note.id)
      assert committed(id) == []
    end

    test "a create that lost the path race leaves no job", %{user: u, vault: v} do
      id = Ecto.UUID.generate()
      once_before_insert(fn -> Engram.Fixtures.insert_note!(u, v, %{path: "race.md"}) end)

      assert {:error, :version_conflict, _} =
               Notes.genesis_crdt_note(u, v, id, "race.md", body: doc_with("body"))

      assert all_enqueued(worker: NoteCommitted) == []
    end

    # The #902 shape: a REST write commits after the room's snapshot, so the
    # checkpoint's version fence matches no row and the write is abandoned.
    test "a checkpoint that lost its fence leaves no job", %{user: u, vault: v} do
      {:ok, note} =
        Notes.upsert_note(u, v, %{"path" => "f.md", "content" => "before"}, actor: "api")

      {:ok, raw} = Repo.with_tenant(u.id, fn -> Engram.Fixtures.raw_note!(note.id) end)
      {:ok, state} = Crypto.decrypt_crdt_state(raw, u)
      {:ok, doc} = CrdtBridge.doc_from_state(state)
      :ok = CrdtBridge.diff_into_text(Yex.Doc.get_text(doc, CrdtBridge.text_name()), "room edit")

      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "f.md", "content" => "rest"}, actor: "api")
      Repo.delete_all(Oban.Job)

      :ok = CrdtCheckpoint.checkpoint(u.id, v.id, note.id, doc, captured_version: raw.version)

      assert committed(note.id) == []
    end
  end

  describe "upsert_note" do
    # Before: three unique inserts (embed, links, finalize) after
    # `with_tenant` returned. Now one plain NoteCommitted in the write's
    # transaction; the dispatcher keeps each downstream job's uniqueness.
    test "a content write queues one NoteCommitted, written in the note's own transaction",
         %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "u.md", "content" => "one"}, actor: "api")

      assert [job] = committed(note.id)
      refute_enqueued(worker: EmbedNote, args: %{note_id: note.id})
      assert same_xmin?(u, note.id, job.id)
    end

    test "a write that rolls back leaves no job", %{user: u, vault: v} do
      {:error, :abort} =
        Repo.transaction_after_commit(fn ->
          {:ok, _} =
            Notes.upsert_note(u, v, %{"path" => "r.md", "content" => "one"}, actor: "api")

          Repo.rollback(:abort)
        end)

      assert all_enqueued(worker: NoteCommitted) == []
    end

    test "an unchanged rewrite queues nothing", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "s.md", "content" => "one"}, actor: "api")
      Repo.delete_all(Oban.Job)
      {:ok, _} = Notes.upsert_note(u, v, %{"path" => "s.md", "content" => "one"}, actor: "api")
      assert committed(note.id) == []
    end

    # #2294: an MCP write keeps its 2 s agent settle through the dispatcher.
    test "an MCP write carries the agent settle to its embed", %{user: u, vault: v} do
      {:ok, note} = Notes.upsert_note(u, v, %{"path" => "m.md", "content" => "one"}, actor: "mcp")
      assert [job] = committed(note.id)
      assert job.args["embed_settle"] == "agent"
      assert job.priority == 0

      :ok = perform_job(NoteCommitted, job.args)
      [embed] = all_enqueued(worker: EmbedNote, args: %{note_id: note.id})

      assert DateTime.diff(embed.scheduled_at, DateTime.utc_now()) <=
               EmbedNote.agent_settle_seconds()
    end
  end

  # Review H1: a delete drops the note's index (embed hashes nulled, points
  # gone), so bringing it back by id needs its jobs even with the same
  # content. Before, only the reconcile sweep (now every 3 h) found it.
  describe "a deleted note brought back by id" do
    setup %{user: u, vault: v} do
      {:ok, note} =
        Notes.upsert_note(u, v, %{"path" => "Old.md", "content" => "# body"}, actor: "api")

      :ok = Notes.delete_note(u, v, "Old.md")
      Repo.delete_all(Oban.Job)
      %{note: note}
    end

    test "an id-keyed REST restore with the same content queues one job",
         %{user: u, vault: v, note: n} do
      {:ok, _} =
        Notes.upsert_note(u, v, %{"id" => n.id, "path" => "New.md", "content" => "# body"},
          actor: "api"
        )

      assert [_] = committed(n.id)
    end

    test "an id-keyed restore with new content queues one job, not two",
         %{user: u, vault: v, note: n} do
      {:ok, _} =
        Notes.upsert_note(u, v, %{"id" => n.id, "path" => "New.md", "content" => "# changed"},
          actor: "api"
        )

      assert [_] = committed(n.id)
    end

    # Delta review D4: the revived note's job keeps the write's own opts.
    test "an MCP restore keeps the agent settle", %{user: u, vault: v, note: n} do
      {:ok, _} =
        Notes.upsert_note(u, v, %{"id" => n.id, "path" => "New.md", "content" => "# body"},
          actor: "mcp"
        )

      assert [job] = committed(n.id)
      assert job.args["embed_settle"] == "agent"
    end

    test "a CRDT resurrect-rename queues one job", %{user: u, vault: v, note: n} do
      {:ok, _} = Notes.genesis_crdt_note(u, v, n.id, "New.md")
      assert [_] = committed(n.id)
    end
  end

  # Rows written by one (sub)transaction share its xid. In the sandbox every
  # `Repo.transaction` is a savepoint with its own subxid, so a job inserted
  # after `with_tenant` returned carries a different xmin from the note.
  defp same_xmin?(user, note_id, job_id) do
    {:ok, {:ok, %{rows: [[a, b]]}}} =
      Repo.with_tenant(user.id, fn ->
        Repo.query(
          "SELECT (SELECT xmin::text FROM notes WHERE id = $1), (SELECT xmin::text FROM oban_jobs WHERE id = $2)",
          [Ecto.UUID.dump!(note_id), job_id]
        )
      end)

    a == b
  end
end
