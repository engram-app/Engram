defmodule Engram.Workers.ProjectVaultIndexTest do
  @moduledoc """
  Projection of `filemeta_v0` onto the `notes` path columns (#1151 step 2).

  This is the half of #1151 that makes a client-owned index usable by everything
  that is NOT the CRDT: REST, search, MCP. The server never reads Yjs state to
  answer "what is this note's path" — it reads the ordinary column, exactly as
  `CrdtCheckpoint` projects note CONTENT for the same reason.

  ## The property that matters most

  Projection is **per entry, and never acts on absence.** No client writes the
  index yet (Engram-obsidian#362), so in prod today it is always empty — and an
  implementation that reconciled by absence would read that as "delete every
  note in the vault". Being additive-corrective is what makes shipping this
  dormant safe rather than terrifying.

  It also means projection can never delete. A note the index does not mention
  is a note projection has no opinion about.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtIndexDoc, CrdtIndexRegistry}
  alias Engram.Workers.{ProjectVaultIndex, ReleaseIndexEntries}
  alias Yex.Sync.SharedDoc

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "ProjectionTest", Ecto.UUID.generate())

    %{user: user, vault: vault}
  end

  defp note(ctx, path) do
    {:ok, note} =
      Notes.upsert_note(ctx.user, ctx.vault, %{"path" => path, "content" => "x"}, actor: "api")

    note
  end

  defp path_of(ctx, note_id) do
    case Notes.get_note_by_id(ctx.user, ctx.vault, note_id) do
      {:ok, %{path: path}} -> path
      _ -> nil
    end
  end

  # Seed the vault's index and persist it, the way a client eventually will.
  defp seed_index(ctx, entries) do
    {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)

    :ok =
      SharedDoc.update_doc(room, fn doc ->
        map = Yex.Doc.get_map(doc, CrdtIndexDoc.map_name())

        # One transaction, so a 5,000-entry seed is one update (one tail row),
        # not 5,000 that outlast the unobserve call's timeout.
        Yex.Doc.transaction(doc, fn ->
          Enum.each(entries, fn {path, id} -> Yex.Map.set(map, path, %{"note_id" => id}) end)
        end)
      end)

    ref = Process.monitor(room)
    :ok = SharedDoc.unobserve(room)
    assert_receive {:DOWN, ^ref, :process, ^room, _}, 5_000
    :ok
  end

  # update_doc/2 returns :ok and discards the fun's value, so a read has to be
  # posted back out of the room process.
  defp read_live(room, path) do
    test_pid = self()

    :ok =
      SharedDoc.update_doc(room, fn doc ->
        result = doc |> Yex.Doc.get_map(CrdtIndexDoc.map_name()) |> Yex.Map.fetch(path)
        send(test_pid, {:live_read, path, result})
      end)

    receive do
      {:live_read, ^path, {:ok, value}} -> value
      {:live_read, ^path, :error} -> nil
    after
      2_000 -> flunk("the live index room never answered a read of #{inspect(path)}")
    end
  end

  # The PERSISTED entries, which is what a claim has to land in when no room is
  # live — reading the live room instead would not prove the snapshot was written.
  defp index_entries(ctx) do
    {:ok, doc} = Engram.Notes.CrdtIndexPersistence.load_doc(ctx.user, ctx.vault.id)
    doc |> Yex.Doc.get_map(CrdtIndexDoc.map_name()) |> Yex.Map.to_map()
  end

  defp tenant_index_ciphertext(ctx) do
    {:ok, row} =
      Repo.with_tenant(ctx.user.id, fn ->
        Repo.get(Engram.Notes.VaultIndexState, ctx.vault.id)
      end)

    row && row.state_ciphertext
  end

  # Releases go through ReleaseIndexEntries so they commit with
  # the caller's transaction and run after it — see that worker's moduledoc.
  defp drain_releases do
    jobs =
      Repo.all(
        from(j in Oban.Job,
          where: j.worker == "Engram.Workers.ReleaseIndexEntries" and j.state == "available"
        )
      )

    Enum.each(jobs, fn job ->
      assert :ok = perform_job(ReleaseIndexEntries, job.args)
    end)

    Repo.delete_all(from(j in Oban.Job, where: j.id in ^Enum.map(jobs, & &1.id)))

    # A link over chunk_size ids enqueues its successor; run the chain out.
    if jobs == [], do: :ok, else: drain_releases()
  end

  defp run(ctx) do
    perform_job(ProjectVaultIndex, %{"user_id" => ctx.user.id, "vault_id" => ctx.vault.id})
  end

  # #1341. The `:user` cache learns of a lock taken on another node only when
  # its eviction lands; these jobs encrypt, so they must read the lock fresh.
  describe "a rotation lock behind a stale cached user" do
    setup ctx do
      Engram.Cache.clear_local(:user)
      _ = Engram.Accounts.get_user(ctx.user.id)

      {1, _} =
        Repo.update_all(
          from(u in Engram.Accounts.User, where: u.id == ^ctx.user.id),
          set: [dek_rotation_locked_at: DateTime.utc_now()]
        )

      # Precondition: the cache still says unlocked (no eviction delivered).
      assert %{dek_rotation_locked_at: nil} = Engram.Accounts.get_user(ctx.user.id)
      :ok
    end

    test "ProjectVaultIndex snoozes", ctx do
      assert {:snooze, 30} = run(ctx)
    end

    test "ReleaseIndexEntries snoozes", ctx do
      assert {:snooze, 30} =
               perform_job(ReleaseIndexEntries, %{
                 "user_id" => ctx.user.id,
                 "vault_id" => ctx.vault.id,
                 "note_ids" => []
               })
    end
  end

  describe "corrective renames" do
    test "an entry whose path differs from the row moves the note", ctx do
      n = note(ctx, "Old/place.md")
      seed_index(ctx, [{"New/place.md", n.id}])

      assert :ok = run(ctx)
      assert path_of(ctx, n.id) == "New/place.md"
    end

    # The no-churn guarantee comes from rename_note/4's {:no_change, note}
    # branch, not from a guard in the worker — this pins the PROPERTY, which is
    # what survives either implementation.
    test "an entry that already agrees changes nothing", ctx do
      n = note(ctx, "Settled/note.md")
      {:ok, before} = Notes.get_note_by_id(ctx.user, ctx.vault, n.id)
      seed_index(ctx, [{"Settled/note.md", n.id}])

      assert :ok = run(ctx)

      {:ok, unchanged} = Notes.get_note_by_id(ctx.user, ctx.vault, n.id)

      assert unchanged.path == before.path
      assert unchanged.version == before.version, "an agreeing entry must not churn the row"
    end
  end

  # A pass reads every entry's note once, then renames from that snapshot's
  # path. If the note moved away and ANOTHER note took its old path in between,
  # a rename by path would move the wrong note. Simulated by moving A and
  # creating C at A's old path right after the snapshot read lands.
  # Peep records 1 for a measurement KEY the event omits (it assumes a
  # counter), so every early-exit emit must carry every key a PromEx metric
  # reads off this event, as 0, or a no-op run reports one released claim.
  describe "telemetry measurements" do
    test "an early-exit run carries every measurement the metrics read", ctx do
      required =
        for %{event_name: [:engram, :crdt, :index_projection], measurement: m} = metric <-
              Engram.PromEx.__metrics_collector_name__()
              |> Peep.Persistent.fetch()
              |> Peep.Persistent.ids_to_metrics()
              |> Map.values(),
            # A counter counts events and reads no measurement.
            not is_struct(metric, Telemetry.Metrics.Counter),
            is_atom(m),
            uniq: true,
            do: m

      assert :released in required

      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :crdt, :index_projection]])
      assert :ok = run(ctx)

      assert_receive {[:engram, :crdt, :index_projection], ^ref, measurements,
                      %{phase: :no_snapshot}}

      assert required -- Map.keys(measurements) == []
      assert measurements.released == 0
    end
  end

  describe "a snapshot-stale path" do
    test "never moves a different note that took the old path", ctx do
      a = note(ctx, "P/a.md")
      seed_index(ctx, [{"R/a.md", a.id}])
      test_pid = self()
      handler_id = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler_id,
        [:engram, :repo, :query],
        fn _event, _measurements, %{query: q}, _config ->
          if self() == test_pid and q =~ ~s("kind" = 'note') and q =~ "ANY(" and
               Process.put(:stale_snapshot_injected, true) == nil do
            {:ok, _} = Notes.rename_note(ctx.user, ctx.vault, "P/a.md", "Q/a.md", index: :skip)
            send(test_pid, {:intruder, note(ctx, "P/a.md")})
          end
        end,
        nil
      )

      try do
        ExUnit.CaptureLog.capture_log(fn -> assert :ok = run(ctx) end)
      after
        :telemetry.detach(handler_id)
      end

      assert_received {:intruder, c}
      assert path_of(ctx, c.id) == "P/a.md"
      assert path_of(ctx, a.id) == "Q/a.md"
    end
  end

  describe "never acts on absence" do
    # THE safety property. In prod today the index is empty for every vault,
    # because no client writes it yet. A projection that reconciled by absence
    # would read that as "this vault has no files".
    test "an empty index leaves every note alone", ctx do
      a = note(ctx, "keep/a.md")
      b = note(ctx, "keep/b.md")
      seed_index(ctx, [])

      assert :ok = run(ctx)

      assert path_of(ctx, a.id) == "keep/a.md"
      assert path_of(ctx, b.id) == "keep/b.md"
    end

    test "a note the index does not mention is untouched", ctx do
      mentioned = note(ctx, "Old/mentioned.md")
      unmentioned = note(ctx, "quiet/unmentioned.md")

      seed_index(ctx, [{"New/mentioned.md", mentioned.id}])

      assert :ok = run(ctx)

      assert path_of(ctx, mentioned.id) == "New/mentioned.md"

      assert path_of(ctx, unmentioned.id) == "quiet/unmentioned.md",
             "projection has no opinion about a note the index never mentions"
    end

    test "a vault with no snapshot at all is a no-op, not an error", ctx do
      n = note(ctx, "untouched.md")

      assert :ok = run(ctx)
      assert path_of(ctx, n.id) == "untouched.md"
    end
  end

  # All three of these were reproduced empirically by an adversarial review
  # before they were fixed. A chain silently half-applied, a swap churned two
  # warnings forever, and a duplicated note_id oscillated a note twice per pass
  # minting tombstones and delete-broadcasts on every checkpoint.
  # Projection makes the index authoritative for paths. So every path the SERVER
  # changes must also land in the index, or the next projection run drags the
  # note back — tombstone at the new path, Qdrant repath, delete broadcast to
  # every device. These pin the dual-write that closes that (#1146 decision 4).
  describe "server-side changes are mirrored into the index" do
    test "a REST rename is NOT reverted by the next projection run", ctx do
      n = note(ctx, "Old/rest.md")
      seed_index(ctx, [{"Old/rest.md", n.id}])

      {:ok, _} = Notes.rename_note(ctx.user, ctx.vault, "Old/rest.md", "New/rest.md")

      assert :ok = run(ctx)

      assert path_of(ctx, n.id) == "New/rest.md",
             "projection dragged a server-side rename back to its old path"
    end

    # Identity has TWO paths: write through a live room, or rewrite the
    # persisted snapshot when there is none. Every other test here stops the
    # room before renaming, so they all exercise the snapshot path — and the
    # live-room branch could be deleted entirely with the suite still green.
    # It is also the branch that runs MOST in prod: a user renaming a note
    # while connected has a live index room.
    test "a rename with the index room LIVE is written through the room", ctx do
      n = note(ctx, "Old/live.md")

      # No on_exit unobserve: the test process IS the observer, so when it exits
      # the room's :DOWN fires auto_exit on its own. An on_exit callback runs in
      # a SEPARATE process after that, so it would call unobserve on a room that
      # has already gone — which exits the caller, the exact hazard
      # release_room/1 guards against (#1382).
      {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)

      :ok =
        SharedDoc.update_doc(room, fn doc ->
          doc
          |> Yex.Doc.get_map(CrdtIndexDoc.map_name())
          |> Yex.Map.set("Old/live.md", %{"note_id" => n.id})
        end)

      {:ok, _} = Notes.rename_note(ctx.user, ctx.vault, "Old/live.md", "New/live.md")

      # Read back out of the LIVE room, not the snapshot: that is what proves
      # the write took the room path rather than silently going to disk.
      assert read_live(room, "New/live.md")["note_id"] == n.id
      refute read_live(room, "Old/live.md")
    end

    # #1341. The snapshot path encrypts, and users.encrypted_dek holds the OLD
    # wrapped dek until final_flip — so a mid-rotation write lands a blob no
    # surviving key can read, on a row the sweep already re-wrapped.
    #
    # Under map-authority the claim IS the commit, so this cannot be
    # skipped-and-continued the way a derived side effect could: the rename
    # fails outright. Half-applying it — row moved, authority not updated — is
    # precisely the state projection would then REVERT.
    test "a rename during a DEK rotation fails instead of half-applying", ctx do
      n = note(ctx, "Old/rot.md")
      seed_index(ctx, [{"Old/rot.md", n.id}])

      before = tenant_index_ciphertext(ctx)

      {1, _} =
        Repo.update_all(
          from(u in Engram.Accounts.User, where: u.id == ^ctx.user.id),
          set: [dek_rotation_locked_at: DateTime.utc_now()]
        )

      user = Repo.get!(Engram.Accounts.User, ctx.user.id)

      assert {:error, :rotation_in_progress} =
               Notes.rename_note(user, ctx.vault, "Old/rot.md", "New/rot.md")

      assert tenant_index_ciphertext(ctx) == before,
             "a refused claim must not touch the snapshot"

      assert path_of(ctx, n.id) == "Old/rot.md",
             "the row must not move when its claim was refused"
    end

    # The cascade used to claim AFTER its rows moved, which is the dual-write
    # ordering this design replaced. A refused claim then left N rows already
    # moved and projection reverted every one of them.
    test "a folder rename whose claim is refused moves no rows", ctx do
      a = note(ctx, "Src/a.md")
      squatter = note(ctx, "elsewhere.md")

      # The authority says Dst/a.md belongs to another note, while no ROW holds
      # it — so only the claim can catch this. A row-level check cannot.
      seed_index(ctx, [{"Src/a.md", a.id}, {"Dst/a.md", squatter.id}])

      assert {:error, :conflict} = Notes.rename_folder(ctx.user, ctx.vault, "Src", "Dst")

      assert path_of(ctx, a.id) == "Src/a.md",
             "the cascade moved rows even though its claim was refused"
    end

    # The batch used to claim per id INSIDE the loop, so a batch failing on a
    # later id had already committed the earlier ones in the authority: the rows
    # rolled back and the next projection run moved them anyway. The API
    # reported a failed batch that then happened regardless.
    test "a batch move that fails claims nothing", ctx do
      a = note(ctx, "a.md")
      seed_index(ctx, [{"a.md", a.id}])

      missing = Ecto.UUID.generate()

      assert {:error, {:not_found, ^missing}} =
               Notes.batch_move_notes(ctx.user, ctx.vault, [a.id, missing], {:path, "Dst"})

      assert path_of(ctx, a.id) == "a.md"

      refute Map.has_key?(index_entries(ctx), "Dst/a.md"),
             "a rolled-back batch left a claim behind, which projection would then apply"
    end

    test "a folder rename cascade is mirrored for every note it moved", ctx do
      a = note(ctx, "Src/a.md")
      b = note(ctx, "Src/b.md")

      seed_index(ctx, [{"Src/a.md", a.id}, {"Src/b.md", b.id}])

      {:ok, _} = Notes.rename_folder(ctx.user, ctx.vault, "Src", "Dst")

      assert :ok = run(ctx)

      assert path_of(ctx, a.id) == "Dst/a.md"
      assert path_of(ctx, b.id) == "Dst/b.md"
    end

    # A deleted note leaves its entry behind otherwise. Projection never
    # resurrects it — get_note_by_id is scoped_live — but the entry then warns
    # and counts as `unresolved` on every checkpoint forever, which is how a
    # real disagreement gets lost in noise.
    test "a deleted note's entry is dropped, so it stops counting as unresolved", ctx do
      attach_projection_telemetry()

      keep = note(ctx, "Old/keep.md")
      doomed = note(ctx, "doomed.md")

      seed_index(ctx, [{"doomed.md", doomed.id}, {"New/keep.md", keep.id}])

      :ok = Notes.delete_note(ctx.user, ctx.vault, "doomed.md")
      :ok = drain_releases()

      assert :ok = run(ctx)

      assert_receive {:projection, %{unresolved: 0}, %{phase: :converged}}, 2_000
      assert path_of(ctx, keep.id) == "New/keep.md"
    end
  end

  describe "entries that interact" do
    defp attach_projection_telemetry do
      test_pid = self()
      handler = "proj-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:engram, :crdt, :index_projection],
        fn _e, m, meta, _ -> send(test_pid, {:projection, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    # a wants b's path; b is vacating it. Entry order is TERM order for small
    # maps, so "b.md" is visited before "c.md" — reliably the losing order. One
    # pass leaves `a` stranded; the fixpoint loop is what lands it.
    test "a chain converges in a single run", ctx do
      a = note(ctx, "a.md")
      b = note(ctx, "b.md")

      seed_index(ctx, [{"b.md", a.id}, {"c.md", b.id}])

      assert :ok = run(ctx)

      assert path_of(ctx, a.id) == "b.md", "the chain must not be left half-applied"
      assert path_of(ctx, b.id) == "c.md"
    end

    # rename_note/4 has no temp-path staging, so a swap can never converge. The
    # loop must HALT on it and report, not churn.
    test "a swap halts and is reported as unresolved rather than churning", ctx do
      attach_projection_telemetry()

      a = note(ctx, "a.md")
      b = note(ctx, "b.md")

      seed_index(ctx, [{"b.md", a.id}, {"a.md", b.id}])

      assert :ok = run(ctx)

      assert path_of(ctx, a.id) == "a.md"
      assert path_of(ctx, b.id) == "b.md"

      assert_receive {:projection, measurements, %{phase: :unresolved}}, 2_000
      assert measurements.applied == 0, "a swap makes no progress by construction"
      assert measurements.passes == 1, "zero progress must stop after ONE pass"
    end

    # Two paths claiming one note cannot both be satisfied. Applying them in
    # sequence moves the note twice per pass — tombstones, seq bumps, Qdrant
    # repaths and delete-broadcasts to every device, on every checkpoint.
    test "a note claimed by two paths is dropped, not oscillated", ctx do
      n = note(ctx, "orig.md")
      other = note(ctx, "Old/other.md")

      seed_index(ctx, [{"x.md", n.id}, {"y.md", n.id}, {"New/other.md", other.id}])

      assert :ok = run(ctx)

      assert path_of(ctx, n.id) == "orig.md",
             "projection cannot pick a winner between two claims, so it moves nothing"

      assert path_of(ctx, other.id) == "New/other.md",
             "an unambiguous entry alongside them still applies"
    end

    test "a converged run reports converged", ctx do
      attach_projection_telemetry()

      n = note(ctx, "Old/fine.md")
      seed_index(ctx, [{"New/fine.md", n.id}])

      assert :ok = run(ctx)

      assert_receive {:projection, %{applied: 1, unresolved: 0}, %{phase: :converged}}, 2_000
    end

    # An empty index and "40 entries, all failed" used to be byte-identical to
    # logs, metrics, Oban and Sentry at once.
    test "an empty index is distinguishable from a failed one", ctx do
      attach_projection_telemetry()

      seed_index(ctx, [])
      assert :ok = run(ctx)

      assert_receive {:projection, %{applied: 0, unresolved: 0}, %{phase: :converged}}, 2_000
    end
  end

  describe "entries it cannot apply" do
    # `path_hmac` is UNIQUE per (user, vault). rename_note/4 pre-checks it and
    # answers {:error, :conflict} rather than crashing — projection must carry
    # that through instead of aborting the whole run.
    test "a collision is skipped and does not stop the rest of the batch", ctx do
      occupant = note(ctx, "taken.md")
      loser = note(ctx, "Old/loser.md")
      other = note(ctx, "Old/other.md")

      seed_index(ctx, [
        {"taken.md", loser.id},
        {"New/other.md", other.id}
      ])

      assert :ok = run(ctx)

      assert path_of(ctx, occupant.id) == "taken.md", "the occupant must not be displaced"
      assert path_of(ctx, loser.id) == "Old/loser.md", "the colliding entry is skipped"

      assert path_of(ctx, other.id) == "New/other.md",
             "one bad entry must not abort the entries after it"
    end

    test "an entry naming a note this vault does not have is skipped", ctx do
      real = note(ctx, "Old/real.md")

      seed_index(ctx, [
        {"ghost.md", Ecto.UUID.generate()},
        {"New/real.md", real.id}
      ])

      assert :ok = run(ctx)
      assert path_of(ctx, real.id) == "New/real.md"
    end

    test "a malformed entry is skipped rather than crashing the job", ctx do
      real = note(ctx, "Old/shape.md")

      {:ok, room} = CrdtIndexRegistry.ensure_observed(ctx.user.id, ctx.vault.id)

      :ok =
        SharedDoc.update_doc(room, fn doc ->
          map = Yex.Doc.get_map(doc, CrdtIndexDoc.map_name())
          Yex.Map.set(map, "junk.md", "not-a-map")
          Yex.Map.set(map, "New/shape.md", %{"note_id" => real.id})
        end)

      ref = Process.monitor(room)
      :ok = SharedDoc.unobserve(room)
      assert_receive {:DOWN, ^ref, :process, ^room, _}, 5_000

      assert :ok = run(ctx)
      assert path_of(ctx, real.id) == "New/shape.md"
    end
  end

  # #1550: a client can claim a path before `crdt_create` is acked. If the
  # create never lands, the claim outlives it and names a note that will never
  # exist. Age (encoded in the note_id's own UUIDv7 bits) is the only signal
  # available to tell that apart from a create still in flight.
  describe "a claim for a note that never arrives (#1550)" do
    test "a claim younger than the grace period is left alone, not released", ctx do
      attach_projection_telemetry()

      real = note(ctx, "Old/real.md")
      in_flight_id = UUIDv7.generate()

      seed_index(ctx, [
        {"ghost.md", in_flight_id},
        {"New/real.md", real.id}
      ])

      assert :ok = run(ctx)

      assert_receive {:projection, %{unresolved: 1, released: 0}, %{phase: :unresolved}}, 2_000
      assert path_of(ctx, real.id) == "New/real.md"
      assert %{"note_id" => ^in_flight_id} = index_entries(ctx)["ghost.md"]

      :ok = drain_releases()

      assert %{"note_id" => ^in_flight_id} = index_entries(ctx)["ghost.md"],
             "a claim still inside the grace period must not be released"
    end

    test "a claim older than the grace period is released and stops counting as unresolved",
         ctx do
      attach_projection_telemetry()

      real = note(ctx, "Old/real.md")
      stale_id = UUIDv7.generate(System.system_time(:millisecond) - :timer.hours(2))

      seed_index(ctx, [
        {"ghost.md", stale_id},
        {"New/real.md", real.id}
      ])

      assert :ok = run(ctx)

      assert_receive {:projection, %{unresolved: 0, released: 1}, %{phase: :converged}}, 2_000
      assert path_of(ctx, real.id) == "New/real.md"

      :ok = drain_releases()

      refute Map.has_key?(index_entries(ctx), "ghost.md"),
             "the stale claim must be gone once the release job runs"
    end

    # Third review pass: detection and release are two different moments —
    # ProjectVaultIndex enqueues the release when it FIRST sees the note
    # missing, but the job runs later. If the real create lands in that
    # window, Identity.release/3 deletes by note_id unconditionally with no
    # check that the note is still gone, so the just-arrived note would be
    # un-indexed by a release job aimed at a note that no longer matches its
    # own premise.
    test "a note that arrives after detection but before the release job runs keeps its entry",
         ctx do
      attach_projection_telemetry()

      stale_id = UUIDv7.generate(System.system_time(:millisecond) - :timer.hours(2))

      seed_index(ctx, [{"ghost.md", stale_id}])

      assert :ok = run(ctx)
      assert_receive {:projection, %{released: 1}, %{phase: :converged}}, 2_000

      # The overdue create finally lands, reusing the same id the release job
      # already targets.
      {:ok, _late_arrival} =
        Notes.upsert_note(
          ctx.user,
          ctx.vault,
          %{
            "id" => stale_id,
            "path" => "ghost.md",
            "content" => "finally here"
          },
          actor: "api"
        )

      :ok = drain_releases()

      assert %{"note_id" => ^stale_id} = index_entries(ctx)["ghost.md"],
             "a note that arrived before the release job ran must not be un-indexed"
    end

    test "a v4 id (not UUIDv7) is never treated as stale", ctx do
      attach_projection_telemetry()

      real = note(ctx, "Old/real.md")
      v4_id = Ecto.UUID.generate()

      seed_index(ctx, [
        {"ghost.md", v4_id},
        {"New/real.md", real.id}
      ])

      assert :ok = run(ctx)

      assert_receive {:projection, %{unresolved: 1, released: 0}, %{phase: :unresolved}}, 2_000
      assert %{"note_id" => ^v4_id} = index_entries(ctx)["ghost.md"]
    end

    # The fixpoint loop used to retry the FULL entries list on every pass, so a
    # stale claim sharing a run with a rename chain (which forces a second
    # pass) got re-detected and re-released each pass — one duplicate
    # ReleaseIndexEntries job per extra pass, up to @max_passes.
    test "a stale claim shares a run with a chain and is released only once", ctx do
      attach_projection_telemetry()

      a = note(ctx, "a.md")
      b = note(ctx, "b.md")
      stale_id = UUIDv7.generate(System.system_time(:millisecond) - :timer.hours(2))

      # b.md -> a.id: a wants b's path, and b is vacating it — a chain that
      # needs a second pass, exactly the condition that used to double-release.
      seed_index(ctx, [
        {"b.md", a.id},
        {"c.md", b.id},
        {"ghost.md", stale_id}
      ])

      assert :ok = run(ctx)

      assert path_of(ctx, a.id) == "b.md", "the chain must still converge"
      assert path_of(ctx, b.id) == "c.md"

      jobs =
        Repo.all(
          from(j in Oban.Job,
            where: j.worker == "Engram.Workers.ReleaseIndexEntries" and j.state == "available"
          )
        )

      assert length(jobs) == 1,
             "one release job per stale claim per run, not one per pass (got #{length(jobs)})"

      # The release happened in pass 1; the chain only converges in pass 2.
      # `released` must survive into the final report, not get overwritten by
      # pass 2's outcome (which never touches the already-released entry).
      assert_receive {:projection, %{unresolved: 0, released: 1}, %{phase: :converged}}, 2_000
    end
  end

  # Prod 2026-10-23, vault f4cd93e6: a first sync left thousands of claims for
  # creates that never landed. Each stale id got its own ReleaseIndexEntries
  # job and log line (4,792, then 14,437+ in one wave), every job a separate
  # index-room edit and encrypted tail append, and the client re-claimed the
  # same ids so it repeated on every checkpoint. Web and worker tasks pinned.
  describe "a stale-claim storm (2026-10-23)" do
    defp stale_ids(n) do
      ms = System.system_time(:millisecond) - :timer.hours(2)
      for _ <- 1..n, do: UUIDv7.generate(ms)
    end

    defp release_jobs do
      Repo.all(
        from(j in Oban.Job,
          where: j.worker == "Engram.Workers.ReleaseIndexEntries" and j.state == "available"
        )
      )
    end

    defp attach_release_telemetry do
      test_pid = self()
      handler = "release-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:engram, :crdt, :index_claim],
        fn
          _e, m, %{op: :release} = meta, _ -> send(test_pid, {:index_release, m, meta})
          _e, _m, _meta, _ -> :ok
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    defp count_messages(tag, n) do
      receive do
        {^tag, _m, _meta} -> count_messages(tag, n + 1)
      after
        200 -> n
      end
    end

    # Performs the vault's release chain one link at a time, asserting at every
    # step that at most ONE release job is waiting: a vault's chunks run in
    # series, so a storm holds at most one `crdt_checkpoint` slot (and one DB
    # connection) instead of every slot queueing on the vault's fold lock.
    defp drain_chain(max_links \\ 1_000) do
      Enum.reduce_while(1..max_links, {0, 0}, fn _, {links, max_mem} ->
        case release_jobs() do
          [] ->
            {:halt, {links, max_mem}}

          [job] ->
            assert :ok = perform_job(ReleaseIndexEntries, job.args)
            Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id))
            {:memory, mem} = Process.info(self(), :memory)
            {:cont, {links + 1, max(max_mem, mem)}}

          jobs ->
            flunk("#{length(jobs)} release jobs runnable at once for one vault, expected 1")
        end
      end)
    end

    # Each link is ONE index-room change of at most chunk_size ids, so the chunk
    # bounds the read, the delete set broadcast to every client, and what a
    # retry redoes. 20,000 ids is the shape the 2026-10-23 storm was heading for.
    # A zero budget makes every link hand off after one chunk, so the chain
    # and its one-link-at-a-time property are exercised at a test-sized cost.
    defp force_chain do
      Application.put_env(:engram, :release_index_link_budget_ms, 0)
      on_exit(fn -> Application.delete_env(:engram, :release_index_link_budget_ms) end)
    end

    test "20,000 stale claims release as ONE chain, a chunk per link, one link at a time",
         ctx do
      force_chain()
      attach_projection_telemetry()
      chunk = ReleaseIndexEntries.chunk_size()
      ids = stale_ids(20_000)
      seed_index(ctx, Enum.with_index(ids, fn id, i -> {"ghost/#{i}.md", id} end))

      {run_us, :ok} = :timer.tc(fn -> run(ctx) end)

      assert [job] = release_jobs()
      assert Enum.sort(job.args["note_ids"]) == Enum.sort(ids)
      assert_receive {:projection, %{released: 20_000, unresolved: 0}, _}, 5_000

      attach_release_telemetry()
      {drain_us, {links, max_mem}} = :timer.tc(fn -> drain_chain() end)

      assert links == div(20_000 + chunk - 1, chunk)

      assert count_messages(:index_release, 0) == links,
             "each link must land as exactly ONE index-room change"

      assert index_entries(ctx) == %{}
      # Generous ceilings for a loaded CI box; a regression to per-id work or an
      # unbounded copy in the job blows through both by an order of magnitude.
      # Memory is THIS process after each link (perform_job runs the worker
      # inline), not the whole VM, so other tests cannot move it. It catches
      # retained growth, not a transient peak.
      assert run_us + drain_us < 120_000_000
      assert max_mem < 256 * 1_048_576
    end

    test "within the link budget, ONE job releases every chunk and enqueues no successor",
         ctx do
      chunk = ReleaseIndexEntries.chunk_size()
      ids = stale_ids(chunk * 2 + 1)
      seed_index(ctx, Enum.with_index(ids, fn id, i -> {"ghost/#{i}.md", id} end))
      assert :ok = run(ctx)

      attach_release_telemetry()
      assert {1, _} = drain_chain()
      assert count_messages(:index_release, 0) == 3, "one index-room change per chunk"
      assert index_entries(ctx) == %{}
    end

    # A real read failure: the user's DEK no longer unwraps (the shape a KMS
    # outage or a rotated-away master key takes), so get_note_meta_by_ids
    # returns an error. The link must release nothing, enqueue no successor
    # (or the rest would run past an unread chunk), and resume on retry.
    test "a failed link keeps the rest of the chain and resumes on retry", ctx do
      force_chain()
      chunk = ReleaseIndexEntries.chunk_size()
      ids = stale_ids(chunk * 2)
      seed_index(ctx, Enum.with_index(ids, fn id, i -> {"ghost/#{i}.md", id} end))
      assert :ok = run(ctx)
      assert [job] = release_jobs()

      original_dek = Repo.reload!(ctx.user).encrypted_dek
      last = byte_size(original_dek) - 1
      <<head::binary-size(last), byte>> = original_dek
      set_dek!(ctx.user, <<head::binary, Bitwise.bxor(byte, 0xFF)>>)

      assert {:error, _} = perform_job(ReleaseIndexEntries, job.args)
      assert [^job] = release_jobs(), "a failed link must not enqueue its successor"

      set_dek!(ctx.user, original_dek)
      assert map_size(index_entries(ctx)) == chunk * 2, "the failed link released nothing"
      assert {2, _} = drain_chain()
      assert index_entries(ctx) == %{}
    end

    defp set_dek!(user, blob) do
      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [encrypted_dek: blob]],
        skip_tenant_check: true
      )

      Engram.Crypto.DekCache.invalidate(user.id)
    end

    test "a release job reads the notes once, however many ids it carries", ctx do
      ids = stale_ids(50)
      seed_index(ctx, Enum.with_index(ids, fn id, i -> {"ghost/#{i}.md", id} end))
      assert :ok = run(ctx)
      [job] = release_jobs()

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:engram, :repo, :query],
        fn _event, _measure, meta, _cfg ->
          if meta[:source] == "notes", do: send(test_pid, {ref, meta[:query]})
        end,
        nil
      )

      try do
        assert :ok = perform_job(ReleaseIndexEntries, job.args)
      after
        :telemetry.detach({__MODULE__, ref})
      end

      assert length(drain_queries(ref, [])) == 1
      assert index_entries(ctx) == %{}
    end

    test "zero stale claims enqueue nothing", ctx do
      real = note(ctx, "Old/real.md")
      seed_index(ctx, [{"New/real.md", real.id}])

      assert :ok = run(ctx)
      assert release_jobs() == []
    end

    test "mixed fresh and stale: only the stale ids are released, in one job", ctx do
      attach_projection_telemetry()
      [s1, s2] = stale_ids(2)
      in_flight = UUIDv7.generate()
      real = note(ctx, "real.md")

      seed_index(ctx, [
        {"g1.md", s1},
        {"g2.md", s2},
        {"in-flight.md", in_flight},
        {"real.md", real.id}
      ])

      assert :ok = run(ctx)

      assert [job] = release_jobs()
      assert Enum.sort(job.args["note_ids"]) == Enum.sort([s1, s2])
      assert_receive {:projection, %{released: 2, unresolved: 1}, _}, 2_000
    end

    test "re-claimed ids are not released again inside the backoff window, then are", ctx do
      attach_projection_telemetry()
      ids = stale_ids(3)
      entries = Enum.with_index(ids, fn id, i -> {"ghost/#{i}.md", id} end)

      seed_index(ctx, entries)
      assert :ok = run(ctx)
      assert [_job] = release_jobs()
      assert_receive {:projection, %{released: 3, release_skipped: 0}, _}, 2_000
      :ok = drain_releases()

      # The client re-claims the same ids, as the incident's client did.
      seed_index(ctx, entries)
      assert :ok = run(ctx)

      assert release_jobs() == [], "a repeat inside the window must not enqueue a release"
      assert_receive {:projection, %{released: 0, release_skipped: 3}, _}, 2_000

      Process.sleep(Engram.Cache.Registry.fetch!(:released_index_claims).ttl + 50)

      assert :ok = run(ctx)
      assert [job] = release_jobs()
      assert Enum.sort(job.args["note_ids"]) == Enum.sort(ids)
      assert_receive {:projection, %{released: 3, release_skipped: 0}, _}, 2_000
    end
  end

  # Prod 2026-10-16: 638 runs/day at ~900 ms each, almost all no-ops. Every
  # entry was a separate tenant transaction plus a full-row fetch and a CONTENT
  # decrypt, though only the path is ever read. One meta query per pass is the
  # budget; this pins that it does not scale with the entry count.
  describe "query budget" do
    test "a no-op run reads the notes once, without content, however many entries", ctx do
      notes = for i <- 1..8, do: note(ctx, "budget/#{i}.md")
      ghosts = for i <- 1..4, do: {"ghost/#{i}.md", Ecto.UUID.generate()}
      seed_index(ctx, Enum.map(notes, &{&1.path, &1.id}) ++ ghosts)

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:engram, :repo, :query],
        fn _event, _measure, meta, _cfg ->
          if meta[:source] == "notes", do: send(test_pid, {ref, meta[:query]})
        end,
        nil
      )

      try do
        assert :ok = run(ctx)
      after
        :telemetry.detach({__MODULE__, ref})
      end

      queries = drain_queries(ref, [])

      assert length(queries) == 1,
             "expected one bulk notes read for 12 entries, got #{length(queries)}"

      refute Enum.any?(queries, &String.contains?(&1, "content_ciphertext")),
             "projection only needs the path; it must not fetch note content"

      for n <- notes, do: assert(path_of(ctx, n.id) == n.path)
    end
  end

  # Not a zero timeout: a handler's send/2 can still be in flight, and for a
  # budget assertion an undercount is a false pass.
  defp drain_queries(ref, acc) do
    receive do
      {^ref, query} -> drain_queries(ref, [query | acc])
    after
      100 -> acc
    end
  end
end
