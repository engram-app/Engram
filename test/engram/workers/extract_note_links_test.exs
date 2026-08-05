defmodule Engram.Workers.ExtractNoteLinksTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Links, Notes, Repo}
  alias Engram.Notes.{CrdtBridge, CrdtCheckpoint, Note}
  alias Engram.Workers.{ExtractNoteLinks, RewriteNoteLinks}

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  test "extracts edges from current note content", %{user: user, vault: vault} do
    {:ok, target} = Notes.upsert_note(user, vault, %{"path" => "Target.md", "content" => "# t"})

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "see [[Target]]"})

    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id})

    assert [%{target_text: "Target", target_note_id: tid, dangling: false}] =
             Links.links_for_note(user, note.id)

    assert tid == target.id
  end

  test "a note emptied to \"\" clears its stale edges (:no_chunks class)",
       %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "see [[X]]"})
    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id})
    assert [_] = Links.links_for_note(user, note.id)

    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => ""})
    assert :ok = perform_job(ExtractNoteLinks, %{note_id: note.id})
    assert [] == Links.links_for_note(user, note.id)
  end

  test "missing note discards", %{user: _user} do
    assert {:discard, _} = perform_job(ExtractNoteLinks, %{note_id: Ecto.UUID.generate()})
  end

  test "soft-deleted note discards", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "D.md", "content" => "x [[Y]]"})
    :ok = Notes.delete_note(user, vault, "D.md")
    assert {:discard, _} = perform_job(ExtractNoteLinks, %{note_id: note.id})
  end

  test "new_debounced dedups per note over available/scheduled", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "S.md", "content" => "a"})

    {:ok, _} = Oban.insert(ExtractNoteLinks.new_debounced(note.id))
    {:ok, _} = Oban.insert(ExtractNoteLinks.new_debounced(note.id))

    assert [job] = all_enqueued(worker: ExtractNoteLinks)
    assert job.args["note_id"] == note.id
    # Leading-edge: ~2s out, never immediate.
    assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
  end

  describe "wiring" do
    test "REST upsert enqueues extraction on content change, not on no-op",
         %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "W.md", "content" => "v1"})
      assert [%{args: %{"note_id" => id}}] = all_enqueued(worker: ExtractNoteLinks)
      assert id == note.id

      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.ExtractNoteLinks"))

      # Idempotent re-push of identical content: no version/seq persisted → no job.
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "W.md", "content" => "v1"})
      assert [] == all_enqueued(worker: ExtractNoteLinks)
    end

    test "CRDT checkpoint content change enqueues extraction",
         %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "C.md", "content" => "old"})
      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.ExtractNoteLinks"))

      {:ok, raw_note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
      {:ok, raw_state} = Crypto.decrypt_crdt_state(raw_note, user)
      {:ok, doc} = CrdtBridge.doc_from_state(raw_state)

      :ok =
        CrdtBridge.diff_into_text(
          Yex.Doc.get_text(doc, CrdtBridge.text_name()),
          "new [[Linked]]"
        )

      :ok = CrdtCheckpoint.checkpoint(user.id, vault.id, note.id, doc)

      assert [%{args: %{"note_id" => id}}] = all_enqueued(worker: ExtractNoteLinks)
      assert id == note.id
    end

    test "REST moved leg (rename resurrect) enqueues extraction on content change, not on same content",
         %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "M1.md", "content" => "before"})
      :ok = Notes.delete_note(user, vault, "M1.md")
      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.ExtractNoteLinks"))

      # Id-keyed rename resurrect (upsert_pathless -> move_note) with DIFFERENT
      # content: hash changes, job enqueued.
      assert {:ok, moved} =
               Notes.upsert_note(user, vault, %{
                 "id" => note.id,
                 "path" => "M2.md",
                 "content" => "after"
               })

      assert [%{args: %{"note_id" => id}}] = all_enqueued(worker: ExtractNoteLinks)
      assert id == moved.id

      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.ExtractNoteLinks"))
      :ok = Notes.delete_note(user, vault, "M2.md")
      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.ExtractNoteLinks"))

      # Same rename resurrect shape, but SAME content as the tombstoned note:
      # merge produces an identical hash, no job.
      assert {:ok, _} =
               Notes.upsert_note(user, vault, %{
                 "id" => note.id,
                 "path" => "M3.md",
                 "content" => "after"
               })

      assert [] == all_enqueued(worker: ExtractNoteLinks)
    end

    test "batch upsert enqueues one extraction job per changed note", %{
      user: user,
      vault: vault
    } do
      notes = [
        %{"path" => "ba.md", "content" => "alpha", "mtime" => 1.0},
        %{"path" => "bb.md", "content" => "beta", "mtime" => 1.0}
      ]

      assert {:ok, %{results: results}} = Notes.batch_upsert_notes(user, vault, notes)
      ids = Enum.map(results, & &1.id)

      jobs = all_enqueued(worker: ExtractNoteLinks)
      assert Enum.sort(Enum.map(jobs, & &1.args["note_id"])) == Enum.sort(ids)
    end

    test "batch upsert skips the extraction job when content is unchanged", %{
      user: user,
      vault: vault
    } do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "bc.md", "content" => "same"})
      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.ExtractNoteLinks"))

      assert {:ok, %{results: [%{status: :ok}]}} =
               Notes.batch_upsert_notes(user, vault, [
                 %{"path" => "bc.md", "content" => "same", "mtime" => 2.0}
               ])

      assert [] == all_enqueued(worker: ExtractNoteLinks)
    end
  end

  describe "bind-time rename repair (lever 2)" do
    import Ecto.Query

    defp clear_jobs!(worker) do
      Repo.delete_all(from(j in Oban.Job, where: j.worker == ^worker))
    end

    test "late dangling edge re-enqueues the rename's rewrite as an immediate sweep",
         %{user: user, vault: vault} do
      {:ok, _note} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
      {:ok, renamed} = Notes.rename_note(user, vault, "Old.md", "Fresh.md")
      # The rename's own chain "already ran": leave its job ROW (the repair
      # evidence) but no pending sweep, simulating rename+60s having passed.
      [rename_job] = all_enqueued(worker: RewriteNoteLinks)
      clear_jobs!("Engram.Workers.RewriteNoteLinks")
      {:ok, _} = Oban.insert(RewriteNoteLinks.new(rename_job.args))
      # Park the evidence row out of available state so drain-style helpers
      # can't run it; the repair query matches any state within the window.
      Repo.update_all(
        from(j in Oban.Job, where: j.worker == "Engram.Workers.RewriteNoteLinks"),
        set: [state: "completed", completed_at: DateTime.utc_now()]
      )

      # Offline device's note arrives NOW, still referencing the old name.
      {:ok, late} =
        Notes.upsert_note(user, vault, %{"path" => "Late.md", "content" => "see [[Old]]"})

      assert :ok = perform_job(ExtractNoteLinks, %{note_id: late.id})

      assert [repair] =
               all_enqueued(worker: RewriteNoteLinks)

      assert repair.args["sweep"] == true
      assert repair.args["cursor"] == "00000000-0000-0000-0000-000000000000"
      assert repair.args["target_id"] == renamed.id
      assert repair.args["old_basename_hmac"] == rename_job.args["old_basename_hmac"]
    end

    test "repair converges: performing the repair rewrites the source and a re-extract enqueues nothing (loop-breaker)",
         %{user: user, vault: vault} do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
      {:ok, _renamed} = Notes.rename_note(user, vault, "Old.md", "Fresh.md")
      [rename_job] = all_enqueued(worker: RewriteNoteLinks)
      clear_jobs!("Engram.Workers.RewriteNoteLinks")
      {:ok, _} = Oban.insert(RewriteNoteLinks.new(rename_job.args))

      Repo.update_all(
        from(j in Oban.Job, where: j.worker == "Engram.Workers.RewriteNoteLinks"),
        set: [state: "completed", completed_at: DateTime.utc_now()]
      )

      {:ok, late} =
        Notes.upsert_note(user, vault, %{"path" => "Late.md", "content" => "see [[Old]]"})

      assert :ok = perform_job(ExtractNoteLinks, %{note_id: late.id})
      [repair] = all_enqueued(worker: RewriteNoteLinks)

      # Run the repair chain: the source note's text gets rewritten [[Old]]→[[Fresh]].
      assert :ok = perform_job(RewriteNoteLinks, repair.args)
      clear_jobs!("Engram.Workers.RewriteNoteLinks")

      # Re-extraction (as the rewrite's own persistence hooks would trigger):
      # edges now carry the NEW basename hmac → no prior-job match → NO repair.
      assert :ok = perform_job(ExtractNoteLinks, %{note_id: late.id})
      assert [] == all_enqueued(worker: RewriteNoteLinks)
      assert [%{dangling: false}] = Links.links_for_note(user, late.id)
    end

    test "repair dedups against the rename's still-pending sweep",
         %{user: user, vault: vault} do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
      {:ok, _} = Notes.rename_note(user, vault, "Old.md", "Fresh.md")
      # Keep the rename's enqueued job AS the pending work (scheduled/available).
      assert [_pending] = all_enqueued(worker: RewriteNoteLinks)

      {:ok, late} =
        Notes.upsert_note(user, vault, %{"path" => "Late.md", "content" => "see [[Old]]"})

      assert :ok = perform_job(ExtractNoteLinks, %{note_id: late.id})

      # Still exactly one job: the repair insert deduped via unique keys
      # [target_id, old_basename_hmac] over available/scheduled.
      assert [_only] = all_enqueued(worker: RewriteNoteLinks)
    end

    test "dangling edge with NO recent rename enqueues nothing",
         %{user: user, vault: vault} do
      {:ok, late} =
        Notes.upsert_note(user, vault, %{"path" => "L.md", "content" => "see [[NeverExisted]]"})

      assert :ok = perform_job(ExtractNoteLinks, %{note_id: late.id})
      assert [] == all_enqueued(worker: RewriteNoteLinks)
    end

    test "rename evidence OLDER than the 10-minute repair window is not repaired",
         %{user: user, vault: vault} do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
      {:ok, _renamed} = Notes.rename_note(user, vault, "Old.md", "Fresh.md")
      [rename_job] = all_enqueued(worker: RewriteNoteLinks)
      clear_jobs!("Engram.Workers.RewriteNoteLinks")
      {:ok, _} = Oban.insert(RewriteNoteLinks.new(rename_job.args))

      # Evidence row is real (completed) but backdated past the 600s window —
      # this is a stale rename, not a recent one; the +60s sweep already had
      # its shot, and re-running it now would be an unbounded resurrection of
      # arbitrarily old renames, not the late-index race lever 2 targets.
      Repo.update_all(
        from(j in Oban.Job, where: j.worker == "Engram.Workers.RewriteNoteLinks"),
        set: [
          state: "completed",
          completed_at: DateTime.utc_now(),
          inserted_at: DateTime.add(DateTime.utc_now(), -601, :second)
        ]
      )

      {:ok, late} =
        Notes.upsert_note(user, vault, %{"path" => "Late.md", "content" => "see [[Old]]"})

      assert :ok = perform_job(ExtractNoteLinks, %{note_id: late.id})
      assert [] == all_enqueued(worker: RewriteNoteLinks)
    end

    test "CRDT-origin rename (ciphertext args, no tombstone) is repairable — args ride verbatim",
         %{user: user, vault: vault} do
      {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
      {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Fresh.md", origin: "web")
      [crdt_job] = all_enqueued(worker: RewriteNoteLinks)
      assert Map.has_key?(crdt_job.args, "old_path_ciphertext")

      Repo.update_all(
        from(j in Oban.Job, where: j.worker == "Engram.Workers.RewriteNoteLinks"),
        set: [state: "completed", completed_at: DateTime.utc_now()]
      )

      {:ok, late} =
        Notes.upsert_note(user, vault, %{"path" => "Late.md", "content" => "see [[Old]]"})

      assert :ok = perform_job(ExtractNoteLinks, %{note_id: late.id})

      assert [repair] = all_enqueued(worker: RewriteNoteLinks)
      assert repair.args["old_path_ciphertext"] == crdt_job.args["old_path_ciphertext"]
      assert repair.args["sweep"] == true
    end
  end
end
