defmodule Engram.Workers.RewriteNoteLinksTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Folders
  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Notes
  alias Engram.Workers.RebindNoteLinks
  alias Engram.Workers.RewriteNoteLinks

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp seed_rename!(user, vault) do
    # Real rename so the OLD-path tombstone exists (the worker recovers
    # old_path from it): create at Old.md, rename to Fresh.md.
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
    {:ok, renamed} = Notes.rename_note(user, vault, "Old.md", "Fresh.md")

    # rename_note's own wiring (Task 6, #648/#1231) fire-and-forget enqueues
    # a RewriteNoteLinks job here. These tests drive the chain BY HAND
    # (perform_job with a hand-picked batch_size, or a manually inserted job
    # + drain_queue) and assert on queue contents / exact batch behavior, so
    # they must start from an empty queue — otherwise the wiring job either
    # breaks an `all_enqueued` count or (worse) silently rewrites everything
    # itself in one big batch before the hand-driven chain under test ever
    # runs, making the assertions vacuous.
    Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.RewriteNoteLinks"))

    {note.id, renamed}
  end

  defp seed_source!(user, vault, path, content) do
    {:ok, source} = Notes.upsert_note(user, vault, %{"path" => path, "content" => content})
    :ok = Links.replace_links(user, vault, source.id, Parser.extract(content))
    source
  end

  defp args_for(user, vault, renamed) do
    %{
      "user_id" => user.id,
      "vault_id" => vault.id,
      "target_kind" => "note",
      "target_id" => renamed.id,
      "old_path_hmac" => old_path_hmac_b64(user, "Old.md"),
      "old_basename_hmac" =>
        Base.encode64(Links.basename_hmac(user, Links.basename_key("Old.md")))
    }
  end

  defp old_path_hmac_b64(user, path) do
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    Base.encode64(Engram.Crypto.hmac_field(filter_key, path))
  end

  defp authoritative!(user, note_id) do
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get(Engram.Notes.Note, note_id) end)
    {:ok, text} = Notes.authoritative_content(user, raw)
    text
  end

  # Drain every enqueued rewrite + rebind job, including cursor successors a
  # rewrite job enqueues mid-run. Loops until the queues are quiet.
  defp drain_link_jobs! do
    jobs =
      all_enqueued(worker: RewriteNoteLinks) ++ all_enqueued(worker: RebindNoteLinks)

    case jobs do
      [] ->
        :ok

      jobs ->
        for %{worker: w, args: args} <- jobs do
          worker = String.to_existing_atom("Elixir." <> w)
          perform_job(worker, args)
        end

        Repo.delete_all(
          from(j in Oban.Job,
            where:
              j.worker in ^["Engram.Workers.RewriteNoteLinks", "Engram.Workers.RebindNoteLinks"] and
                j.state == "available"
          )
        )

        drain_link_jobs!()
    end
  end

  describe "folder rename round trip (Phase 3, #1231)" do
    test "rewrites qualified links, preserves bare links, rebinds edges + danglers", %{
      user: user,
      vault: vault
    } do
      {:ok, guide} =
        Notes.upsert_note(user, vault, %{"path" => "docs/Guide.md", "content" => "# g"})

      # Source OUTSIDE the folder: one qualified + one bare occurrence.
      refs = seed_source!(user, vault, "Refs.md", "see [[docs/Guide]] and [[Guide]]")

      # Source INSIDE the renamed folder referencing a sibling — its own path
      # moves in the same cascade; the rewrite must still land on its doc.
      index = seed_source!(user, vault, "docs/Index.md", "sibling [[docs/Guide]]")

      # Pre-typed dangler on the FUTURE path — must BIND after the move via
      # the rebind fan-out, with NO text change.
      future = seed_source!(user, vault, "Future.md", "soon [[archive/Guide]]")

      {:ok, %{notes: 2, attachments: 0}} = Folders.rename(user, vault, "docs", "archive")
      drain_link_jobs!()

      assert authoritative!(user, refs.id) == "see [[archive/Guide]] and [[Guide]]"
      assert authoritative!(user, index.id) == "sibling [[archive/Guide]]"
      assert authoritative!(user, future.id) == "soon [[archive/Guide]]"

      # #1231: every edge now binds to the moved note — including the
      # previously-dangling Future.md edge.
      edges =
        Repo.all(
          from(l in Engram.Links.NoteLink,
            where:
              l.user_id == ^user.id and l.vault_id == ^vault.id and
                l.source_note_id in ^[refs.id, index.id, future.id],
            select: {l.source_note_id, l.target_note_id}
          ),
          skip_tenant_check: true
        )

      assert length(edges) == 4
      assert Enum.all?(edges, fn {_src, target} -> target == guide.id end)
    end
  end

  test "rewrites every source note and chains by cursor", %{user: user, vault: vault} do
    {_old_id, renamed} = seed_rename!(user, vault)
    sources = for i <- 1..3, do: seed_source!(user, vault, "S#{i}.md", "see [[Old]] #{i}")

    args = Map.put(args_for(user, vault, renamed), "batch_size", 2)
    assert :ok = perform_job(RewriteNoteLinks, args)

    # Batch of 2 full -> successor enqueued with a cursor.
    assert [job] = all_enqueued(worker: RewriteNoteLinks)
    assert job.args["cursor"] > "00000000-0000-0000-0000-000000000000"
    assert :ok = perform_job(RewriteNoteLinks, job.args)

    for {s, i} <- Enum.with_index(sources, 1) do
      assert authoritative!(user, s.id) == "see [[Fresh]] #{i}"
    end
  end

  # Regression for the no-`unique:` invariant. `Oban.insert/1` called twice
  # back-to-back never proves anything: both rows land in `available`, none
  # is ever `executing`, so a `unique: [..., states: [:executing]]` option
  # wouldn't even fire. The real trap is a self-re-enqueue racing its OWN
  # still-`executing` row — reproduced here with `Oban.drain_queue/1`, which
  # goes through the real fetch_jobs path (state -> "executing" before
  # `perform/1` runs), same technique as
  # BackfillNoteLinksTest."survives multiple same-scope batches under real
  # Oban dispatch (no unique collision)".
  #
  # Proof this test catches the regression: temporarily restoring
  # `unique: [keys: [:user_id, :vault_id, :target_kind, :target_id], states: [:executing]]`
  # on the worker makes this test fail (only 1 of 3 sources gets rewritten —
  # the batch-2/3 self-re-enqueues collide with the still-executing batch-1
  # row and get silently dropped) — see task-5-report.md, "Fix round 1".
  test "survives multiple batches under real Oban dispatch (no unique collision)", %{
    user: user,
    vault: vault
  } do
    {_old_id, renamed} = seed_rename!(user, vault)
    sources = for i <- 1..3, do: seed_source!(user, vault, "S#{i}.md", "see [[Old]] #{i}")

    {:ok, _job} =
      args_for(user, vault, renamed)
      |> Map.put("batch_size", 1)
      |> RewriteNoteLinks.new()
      |> Oban.insert()

    result = Oban.drain_queue(queue: :indexing, with_recursion: true)
    assert result.failure == 0, "chain must not raise/fail: #{inspect(result)}"

    for {s, i} <- Enum.with_index(sources, 1) do
      assert authoritative!(user, s.id) == "see [[Fresh]] #{i}",
             "source #{s.id} never rewrote — same-batch-size cursor loop stalled"
    end
  end

  test "per-source failure is isolated: the healthy sibling still rewrites", %{
    user: user,
    vault: vault
  } do
    {_old_id, renamed} = seed_rename!(user, vault)
    bad = seed_source!(user, vault, "Bad.md", "see [[Old]]")
    good = seed_source!(user, vault, "Good.md", "see [[Old]]")

    # Corrupt the bad source's CRDT snapshot so decrypt fails.
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        from(n in Engram.Notes.Note, where: n.id == ^bad.id)
        |> Repo.update_all(set: [crdt_state_ciphertext: <<1, 2, 3>>, crdt_state_nonce: <<0>>])
      end)

    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :links, :rewrite, :failed]])
    on_exit(fn -> :telemetry.detach(ref) end)

    assert :ok = perform_job(RewriteNoteLinks, args_for(user, vault, renamed))

    assert authoritative!(user, good.id) == "see [[Fresh]]"

    # The corrupt snapshot fails decrypt — and the emitted :reason is the
    # closed-set atom, proving a real failure rides the bounded label.
    assert_receive {[:engram, :links, :rewrite, :failed], ^ref, %{count: 1},
                    %{reason: :decrypt_failed}}
  end

  # [:engram, :links, :rewrite, :failed]'s :reason feeds a Prometheus label
  # (PromEx.Indexing) whose cardinality contract is "closed enums only" —
  # Telemetry.error_kind/1 alone maps unknown exceptions to their struct
  # module, an open set. Pin the emit-site bucketing.
  describe "telemetry_failure_reason/1 — closed :reason label set (#1240 review)" do
    test "known pipeline error atoms pass through" do
      for reason <- [
            :head_advanced,
            :room_gone,
            :target_gone,
            :version_conflict,
            :path_undecryptable,
            :decrypt_failed,
            :old_path_unrecoverable
          ] do
        assert RewriteNoteLinks.telemetry_failure_reason(reason) == reason
      end
    end

    test "an unknown exception buckets to :exception, never its struct module" do
      assert RewriteNoteLinks.telemetry_failure_reason(%RuntimeError{message: "boom"}) ==
               :exception

      assert RewriteNoteLinks.telemetry_failure_reason(%ArgumentError{}) == :exception
    end

    test "arbitrary shapes bucket to :other" do
      assert RewriteNoteLinks.telemetry_failure_reason(:some_unknown_atom) == :other
      assert RewriteNoteLinks.telemetry_failure_reason({:weird_tag, "x"}) == :other
      assert RewriteNoteLinks.telemetry_failure_reason("string") == :other
    end
  end

  test "missing tombstone discards without raising", %{user: user, vault: vault} do
    {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "x"})

    args =
      args_for(user, vault, renamed)
      |> Map.put("old_path_hmac", old_path_hmac_b64(user, "NeverExisted.md"))

    assert {:discard, :old_path_unrecoverable} = perform_job(RewriteNoteLinks, args)
  end

  # Phase 2: CRDT relocates leave NO tombstone at the old path (move_note is
  # an in-place repoint) — the job carries the old path as user-DEK AES-GCM
  # ciphertext instead, AAD-bound to the target row id.
  defp ciphertext_args(user, vault, target, old_path) do
    {:ok, dek} = Engram.Crypto.get_dek(user)
    aad = Engram.Crypto.aad_for_row("oban_rewrite_note_links", "old_path", target.id)
    {ct, nonce} = Engram.Crypto.Envelope.encrypt(old_path, dek, aad)

    %{
      "user_id" => user.id,
      "vault_id" => vault.id,
      "target_kind" => "note",
      "target_id" => target.id,
      "old_path_hmac" => old_path_hmac_b64(user, old_path),
      "old_basename_hmac" =>
        Base.encode64(Links.basename_hmac(user, Links.basename_key(old_path))),
      "old_path_ciphertext" => Base.encode64(ct),
      "old_path_nonce" => Base.encode64(nonce)
    }
  end

  test "recovers old_path from encrypted args when NO tombstone exists (CRDT relocate)",
       %{user: user, vault: vault} do
    # Relocate via the CRDT genesis path, NOT rename_note — proves the
    # no-tombstone premise instead of assuming it.
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"})
    source = seed_source!(user, vault, "S.md", "see [[Old]]")
    {:ok, _moved} = Notes.genesis_crdt_note(user, vault, note.id, "Fresh.md")

    # Premise pin: the relocate left no soft-deleted row anywhere.
    tombs =
      Repo.one(
        from(n in Engram.Notes.Note,
          where: n.user_id == ^user.id and not is_nil(n.deleted_at),
          select: count(n.id)
        ),
        skip_tenant_check: true
      )

    assert tombs == 0

    assert :ok = perform_job(RewriteNoteLinks, ciphertext_args(user, vault, note, "Old.md"))
    assert authoritative!(user, source.id) =~ "[[Fresh]]"
    refute authoritative!(user, source.id) =~ "[[Old]]"
  end

  test "AAD binds the ciphertext to the target id — foreign ciphertext discards",
       %{user: user, vault: vault} do
    {:ok, a} = Notes.upsert_note(user, vault, %{"path" => "A-old.md", "content" => "a"})
    {:ok, b} = Notes.upsert_note(user, vault, %{"path" => "B.md", "content" => "b"})
    {:ok, _} = Notes.genesis_crdt_note(user, vault, a.id, "A-new.md")

    # Ciphertext minted for target A, replayed onto a job for target B.
    args =
      user
      |> ciphertext_args(vault, a, "A-old.md")
      |> Map.put("target_id", b.id)

    assert {:discard, :old_path_unrecoverable} = perform_job(RewriteNoteLinks, args)
  end

  test "garbage ciphertext args discard without raising", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "G-old.md", "content" => "g"})
    {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "G-new.md")

    args =
      user
      |> ciphertext_args(vault, note, "G-old.md")
      |> Map.put("old_path_ciphertext", Base.encode64("not a real ciphertext"))

    assert {:discard, :old_path_unrecoverable} = perform_job(RewriteNoteLinks, args)
  end

  # Phase 2 (#648/#1231, task 3) — enqueue and perform live in different
  # functions/modules (Notes.enqueue_crdt_rename_rewrite vs this worker's
  # decrypt). Only a round trip through the real Oban args proves both sides
  # agree on the AAD contract; a unit test of either side alone could pass
  # with mismatched AAD and never notice.
  test "web-origin relocate job round-trips: enqueue args alone recover the old path",
       %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "Rt-old.md", "content" => "# t"})
    source = seed_source!(user, vault, "RtSource.md", "see [[Rt-old]]")
    {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Rt-new.md", origin: "web")

    assert [job] = all_enqueued(worker: RewriteNoteLinks)
    assert :ok = perform_job(RewriteNoteLinks, job.args)
    assert authoritative!(user, source.id) =~ "[[Rt-new]]"
  end
end
