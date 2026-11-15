defmodule Engram.Workers.RewriteNoteLinksTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Folders
  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Notes
  alias Engram.Workers.RewriteNoteLinks

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp seed_rename!(user, vault) do
    # Real rename so the OLD-path tombstone exists (the worker recovers
    # old_path from it): create at Old.md, rename to Fresh.md.
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"}, actor: "api")

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
    {:ok, source} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

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
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Engram.Fixtures.raw_note(note_id) end)
    {:ok, text} = Notes.authoritative_content(user, raw)
    text
  end

  # Drain every enqueued rewrite job, including cursor successors a
  # rewrite job enqueues mid-run AND the delayed sweep job a terminating
  # chain now enqueues (schedule_in: 60 -> state "scheduled", not
  # "available" — must be swept up here too or this loop never quiesces).
  # Loops until the queues are quiet.
  defp drain_link_jobs! do
    case all_enqueued(worker: RewriteNoteLinks) do
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
              j.worker == "Engram.Workers.RewriteNoteLinks" and
                j.state in ["available", "scheduled"]
          )
        )

        drain_link_jobs!()
    end
  end

  describe "folder rename round trip (Phase 3, #1231)" do
    test "rewrites qualified links, preserves bare links, edges + danglers resolve", %{
      user: user,
      vault: vault
    } do
      {:ok, guide} =
        Notes.upsert_note(user, vault, %{"path" => "docs/Guide.md", "content" => "# g"},
          actor: "api"
        )

      # Source OUTSIDE the folder: one qualified + one bare occurrence.
      refs = seed_source!(user, vault, "Refs.md", "see [[docs/Guide]] and [[Guide]]")

      # Source INSIDE the renamed folder referencing a sibling — its own path
      # moves in the same cascade; the rewrite must still land on its doc.
      index = seed_source!(user, vault, "docs/Index.md", "sibling [[docs/Guide]]")

      # Pre-typed dangler on the FUTURE path — must resolve after the move,
      # with NO text change.
      future = seed_source!(user, vault, "Future.md", "soon [[archive/Guide]]")

      {:ok, %{notes: 2, attachments: 0}} = Folders.rename(user, vault, "docs", "archive")
      drain_link_jobs!()

      assert authoritative!(user, refs.id) == "see [[archive/Guide]] and [[Guide]]"
      assert authoritative!(user, index.id) == "sibling [[archive/Guide]]"
      assert authoritative!(user, future.id) == "soon [[archive/Guide]]"

      # #1231: every edge now resolves to the moved note — including the
      # previously-dangling Future.md edge.
      targets =
        for src <- [refs, index, future],
            link <- Engram.Links.links_for_note(user, src.id),
            do: link.target_note_id

      assert length(targets) == 4
      assert Enum.all?(targets, &(&1 == guide.id))
    end
  end

  describe "nested folder moves and chains" do
    defp forms(prefix, name) do
      "path [[#{prefix}/#{name}]] alias [[#{prefix}/#{name}|G]] heading [[#{prefix}/#{name}#H]] " <>
        "embed ![[#{prefix}/#{name}.md]] md [x](#{prefix}/#{name}.md) bare [[#{name}]]"
    end

    test "a nested folder renamed inside a folder that is then moved: every form follows",
         %{user: user, vault: vault} do
      {:ok, guide} =
        Notes.upsert_note(user, vault, %{"path" => "docs/sub/Guide.md", "content" => "# g"},
          actor: "api"
        )

      refs = seed_source!(user, vault, "Refs.md", forms("docs/sub", "Guide"))

      {:ok, %{notes: 1}} = Folders.rename(user, vault, "docs/sub", "docs/deep")
      drain_link_jobs!()
      assert authoritative!(user, refs.id) == forms("docs/deep", "Guide")

      {:ok, %{notes: 1}} = Folders.rename(user, vault, "docs", "archive")
      drain_link_jobs!()
      assert authoritative!(user, refs.id) == forms("archive/deep", "Guide")

      # Every edge still resolves to the one moved note.
      targets = for l <- Links.links_for_note(user, refs.id), do: l.target_note_id
      assert length(targets) == 6
      assert Enum.all?(targets, &(&1 == guide.id))
    end

    test "a note rename then its folder's move: the new name carries to the new folder",
         %{user: user, vault: vault} do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "docs/sub/Guide.md", "content" => "# g"},
          actor: "api"
        )

      refs = seed_source!(user, vault, "Refs.md", forms("docs/sub", "Guide"))

      {:ok, _} = Notes.rename_note(user, vault, "docs/sub/Guide.md", "docs/sub/Manual.md")
      drain_link_jobs!()
      # The bare link follows a basename change; folder-qualified ones keep their folder.
      assert authoritative!(user, refs.id) == forms("docs/sub", "Manual")

      {:ok, %{notes: 1}} = Folders.rename(user, vault, "docs", "archive")
      drain_link_jobs!()
      # The folder move leaves the bare link alone.
      assert authoritative!(user, refs.id) == forms("archive/sub", "Manual")
    end
  end

  describe "stale link keys" do
    # `link_keys_stamp` NULL or from another Unicode/nonce version means the
    # row's stored key is not trusted. A folder rename must still rewrite and
    # re-stamp such a row, never skip it. The rewrite assertions alone would
    # also pass if stale rows were ignored by key (the walk finds edges by
    # target_note_id); only `stale_count() == 0` (the re-stamp) is sensitive.
    test "rows with a NULL or old stamp are rewritten and re-stamped", %{
      user: user,
      vault: vault
    } do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "docs/Guide.md", "content" => "# g"},
          actor: "api"
        )

      null_src = seed_source!(user, vault, "Null.md", "see [[docs/Guide]]")
      old_src = seed_source!(user, vault, "Old.md", "see [[docs/Guide]]")
      cur_src = seed_source!(user, vault, "Cur.md", "see [[docs/Guide]]")

      Repo.query!(
        "UPDATE note_links SET link_keys_stamp = NULL, target_key_hmac = NULL WHERE source_note_id = $1",
        [Ecto.UUID.dump!(null_src.id)]
      )

      Repo.query!(
        "UPDATE note_links SET link_keys_stamp = '\\x00'::bytea WHERE source_note_id = $1",
        [Ecto.UUID.dump!(old_src.id)]
      )

      assert stale_count() == 2

      {:ok, %{notes: 1}} = Folders.rename(user, vault, "docs", "archive")
      drain_link_jobs!()

      for s <- [null_src, old_src, cur_src] do
        assert authoritative!(user, s.id) == "see [[archive/Guide]]"
      end

      # The rewrite re-extracted each source: every row is current again.
      assert stale_count() == 0
    end

    defp stale_count do
      version = Links.link_keys_version()

      %{rows: [[n]]} =
        Repo.query!(
          "SELECT count(*) FROM note_links WHERE link_keys_stamp IS DISTINCT FROM (target_text_nonce || $1::bytea)",
          [version]
        )

      n
    end
  end

  describe "late-indexed linker" do
    test "linker written, target renamed before ExtractNoteLinks runs: the sweep rewrites it",
         %{user: user, vault: vault} do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"}, actor: "api")

      # The linker exists, its note_links edge does not (index job not run).
      {:ok, linker} =
        Notes.upsert_note(user, vault, %{"path" => "Late.md", "content" => "see [[Old]]"},
          actor: "api"
        )

      {:ok, renamed} = Notes.rename_note(user, vault, "Old.md", "Fresh.md")
      assert [rename_job] = all_enqueued(worker: RewriteNoteLinks)

      # The rename's walk finds no edge and schedules its ~60s sweep.
      assert :ok = perform_job(RewriteNoteLinks, rename_job.args)
      Repo.delete(rename_job)
      assert [sweep] = all_enqueued(worker: RewriteNoteLinks)
      assert sweep.args["sweep"] == true
      assert authoritative!(user, linker.id) == "see [[Old]]"

      # The index job lands the edge. Its bind-time repair must defer to the
      # pending sweep (unique), not rewrite or enqueue a second job.
      assert :ok =
               perform_job(Engram.Workers.ExtractNoteLinks, %{
                 "user_id" => user.id,
                 "note_id" => linker.id
               })

      assert [_edge] = Links.links_for_note(user, linker.id)
      assert authoritative!(user, linker.id) == "see [[Old]]"
      assert [^sweep] = all_enqueued(worker: RewriteNoteLinks)
      # Relative to the job's own insert time, not the test's wall clock;
      # the worker's @sweep_delay_seconds is 60.
      assert DateTime.diff(sweep.scheduled_at, sweep.inserted_at) in 55..65

      # Drive the sweep itself, no sleeping.
      assert :ok = perform_job(RewriteNoteLinks, sweep.args)
      assert authoritative!(user, linker.id) == "see [[Fresh]]"
      assert [%{target_note_id: id}] = Links.links_for_note(user, linker.id)
      assert id == renamed.id
    end
  end

  describe "folder rename cost (pre-S5)" do
    # PINS TODAY'S O(N) BEHAVIOR. A folder rename of N notes touches 2N note
    # rows (N moved + N old-path tombstones) and enqueues N RewriteNoteLinks
    # jobs. S5 (O(1) folder rename, Engram#2523) must change these
    # assertions: update them in that PR, do not loosen them here.
    test "touched rows, tombstones and rewrite jobs grow linearly with N", %{
      user: user,
      vault: vault
    } do
      for n <- [2, 5] do
        folder = "cost#{n}"

        for i <- 1..n do
          {:ok, _} =
            Notes.upsert_note(user, vault, %{"path" => "#{folder}/N#{i}.md", "content" => "n"},
              actor: "api"
            )
        end

        Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.RewriteNoteLinks"))
        assert {:ok, ^n} = Notes.rename_folder(user, vault, folder, folder <> "x")

        # Every row the op wrote shares its one seq.
        rows =
          Repo.all(
            from(r in Engram.Notes.Note,
              where: r.vault_id == ^vault.id,
              select: {r.seq, r.deleted_at}
            ),
            skip_tenant_check: true
          )

        op_seq = rows |> Enum.map(&elem(&1, 0)) |> Enum.max()
        touched = Enum.filter(rows, &(elem(&1, 0) == op_seq))
        assert length(touched) == 2 * n
        assert Enum.count(touched, &(elem(&1, 1) != nil)) == n
        assert length(all_enqueued(worker: RewriteNoteLinks)) == n
      end
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

  describe "delayed sweep (closes the late-index rewrite window, #1231 follow-up)" do
    test "chain termination without a sweep marker enqueues one delayed sweep job, preserving identity/hmac/ciphertext args",
         %{user: user, vault: vault} do
      # CRDT-relocate style target so the round trip also proves the
      # ciphertext args survive into the sweep job, not just the hmacs.
      {:ok, note} =
        Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"}, actor: "api")

      _source = seed_source!(user, vault, "S.md", "see [[Old]]")
      {:ok, _moved} = Notes.genesis_crdt_note(user, vault, note.id, "Fresh.md")
      Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.RewriteNoteLinks"))

      args = ciphertext_args(user, vault, note, "Old.md")
      assert :ok = perform_job(RewriteNoteLinks, args)

      assert [job] = all_enqueued(worker: RewriteNoteLinks)
      assert job.args["sweep"] == true
      assert job.args["cursor"] == "00000000-0000-0000-0000-000000000000"

      for key <- Map.keys(args), key != "cursor" do
        assert job.args[key] == args[key], "expected #{key} to be preserved on the sweep job"
      end

      diff = DateTime.diff(job.scheduled_at, DateTime.utc_now())
      assert diff in 55..65, "expected ~60s delay, got #{diff}s"
    end

    test "a sweep-marked chain termination enqueues no further job (recursion guard)", %{
      user: user,
      vault: vault
    } do
      {_old_id, renamed} = seed_rename!(user, vault)
      _source = seed_source!(user, vault, "S.md", "see [[Old]]")

      args = args_for(user, vault, renamed) |> Map.put("sweep", true)
      assert :ok = perform_job(RewriteNoteLinks, args)

      assert all_enqueued(worker: RewriteNoteLinks) == []
    end

    test "a full-batch sweep job enqueues its successor with the sweep marker preserved", %{
      user: user,
      vault: vault
    } do
      {_old_id, renamed} = seed_rename!(user, vault)
      _sources = for i <- 1..3, do: seed_source!(user, vault, "S#{i}.md", "see [[Old]] #{i}")

      args =
        args_for(user, vault, renamed)
        |> Map.put("sweep", true)
        |> Map.put("batch_size", 2)

      assert :ok = perform_job(RewriteNoteLinks, args)

      assert [job] = all_enqueued(worker: RewriteNoteLinks)
      assert job.args["sweep"] == true
      assert job.args["cursor"] > "00000000-0000-0000-0000-000000000000"
    end

    test "the bug itself: an edge that lands after the initial walk is caught by the delayed sweep",
         %{user: user, vault: vault} do
      {_old_id, renamed} = seed_rename!(user, vault)

      # Simulate the pre-index state: the referring note exists, but its
      # note_links edge has not been written yet (async indexing lag).
      {:ok, source} =
        Notes.upsert_note(user, vault, %{"path" => "Late.md", "content" => "see [[Old]]"},
          actor: "api"
        )

      args = args_for(user, vault, renamed)
      assert :ok = perform_job(RewriteNoteLinks, args)

      # No edge existed yet -> nothing found -> nothing rewritten.
      assert authoritative!(user, source.id) == "see [[Old]]"
      assert [sweep_job] = all_enqueued(worker: RewriteNoteLinks)
      assert sweep_job.args["sweep"] == true

      # Late indexing arrives: the edge is created now. Old.md is gone
      # (renamed away), so this reads dangling.
      :ok = Links.replace_links(user, vault, source.id, Parser.extract("see [[Old]]"))

      assert dangling_target(user, source.id) == nil

      # The delayed sweep re-walks from the start cursor and catches it.
      assert :ok = perform_job(RewriteNoteLinks, sweep_job.args)

      assert authoritative!(user, source.id) == "see [[Fresh]]"
      assert dangling_target(user, source.id) == renamed.id
    end
  end

  defp dangling_target(user, source_id) do
    [%{target_note_id: id}] = Links.links_for_note(user, source_id)
    id
  end

  # Regression for the no-`unique:` invariant. `Oban.insert/1` called twice
  # back-to-back never proves anything: both rows land in `available`, none
  # is ever `executing`, so a `unique: [..., states: [:executing]]` option
  # wouldn't even fire. The real trap is a self-re-enqueue racing its OWN
  # still-`executing` row — reproduced here with `Oban.drain_queue/1`, which
  # goes through the real fetch_jobs path (state -> "executing" before
  # `perform/1` runs), same technique as
  # the removed note-links backfill test."survives multiple same-scope batches under real
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
        Engram.Fixtures.write_note_body!(bad.id,
          crdt_state_ciphertext: <<1, 2, 3>>,
          crdt_state_nonce: <<0>>
        )
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
    {:ok, renamed} =
      Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "x"}, actor: "api")

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
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# t"}, actor: "api")

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
    {:ok, a} =
      Notes.upsert_note(user, vault, %{"path" => "A-old.md", "content" => "a"}, actor: "api")

    {:ok, b} = Notes.upsert_note(user, vault, %{"path" => "B.md", "content" => "b"}, actor: "api")
    {:ok, _} = Notes.genesis_crdt_note(user, vault, a.id, "A-new.md")

    # Ciphertext minted for target A, replayed onto a job for target B.
    args =
      user
      |> ciphertext_args(vault, a, "A-old.md")
      |> Map.put("target_id", b.id)

    assert {:discard, :old_path_unrecoverable} = perform_job(RewriteNoteLinks, args)
  end

  test "garbage ciphertext args discard without raising", %{user: user, vault: vault} do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "G-old.md", "content" => "g"}, actor: "api")

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
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "Rt-old.md", "content" => "# t"}, actor: "api")

    source = seed_source!(user, vault, "RtSource.md", "see [[Rt-old]]")
    {:ok, _} = Notes.genesis_crdt_note(user, vault, note.id, "Rt-new.md", origin: "web")

    assert [job] = all_enqueued(worker: RewriteNoteLinks)
    assert :ok = perform_job(RewriteNoteLinks, job.args)
    assert authoritative!(user, source.id) =~ "[[Rt-new]]"
  end
end
