defmodule Engram.Workers.ReconcileNotePayloadsTest do
  @moduledoc """
  Self-heal for users a DEK rotation already hit: their rows were rekeyed but
  every point kept the old filter HMACs. The reconcile reads the points,
  rewrites only the drifted ones with `set_payload` (no upsert, no embed) and
  stamps every checked note so the migration converges.

  The notes start on v3 points (`Engram.LegacyPoints`), the layout the
  `set_payload` heal serves; the v5 tests put v5 points over them.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]
  import Mox

  alias Engram.Crypto
  alias Engram.DataMigrations
  alias Engram.DataMigrations.NotePayloadStamps
  alias Engram.Indexing
  alias Engram.Indexing.PayloadV6
  alias Engram.Notes
  alias Engram.Notes.{Chunk, Note, NoteIndexState}
  alias Engram.ServiceConfig
  alias Engram.Vector.{FilterId, QdrantLayout}
  alias Engram.Workers.DataMigrationsRunner
  alias Engram.Workers.ReconcileNotePayloads

  setup :verify_on_exit!

  setup do
    {:ok, store} =
      Agent.start_link(fn ->
        %{
          points: %{},
          upserts: 0,
          set_payloads: [],
          overwrites: [],
          batches: [],
          on_scroll: nil,
          on_write: nil,
          on_upsert: nil,
          payload_status: 200,
          scroll_status: nil,
          batch_status: nil,
          legacy_indexes: true,
          schema: %{"u" => %{}, "v" => %{}, "n" => %{"data_type" => "uuid"}},
          requests: []
        }
      end)

    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    Bypass.stub(bypass, :any, :any, &fake_qdrant(&1, store))
    # The `n` backfill is paced on the collection's health (`Rebuild.qdrant_pace/1`).
    # The ledger's done also needs the collection's `n` index (`schema`).
    Engram.QdrantStub.stub_healthy(bypass, "engram_notes",
      payload_schema: fn -> Agent.get(store, & &1.schema) end
    )

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture(dek_version: 1)
    vault = Engram.Fixtures.insert_vault!(user, "HealVault")

    [stale, healthy] =
      for path <- ["Ops/Stale.md", "Ops/Healthy.md"] do
        {:ok, note} =
          Notes.upsert_note(
            user,
            vault,
            %{
              "path" => path,
              "content" => "---\ntype: Playbook\ntags: [ops]\n---\n# T\n\nBody.\n"
            },
            actor: "api"
          )

        {:ok, plain} = Crypto.maybe_decrypt_note_fields(note, user)
        assert {:ok, _} = Indexing.index_note(plain, vault)
        # Indexed before the v5 layout: v3 points.
        Engram.LegacyPoints.rekey!(note, user, store)
        note
      end

    # Written before `payload_hash` existed; keyword vectors current, as
    # EmbedNote stamps them.
    {2, _} =
      Repo.update_all(
        from(n in Note, where: n.user_id == ^user.id),
        [set: [payload_hash: nil, keyword_version: Engram.KeywordIndex.version()]],
        skip_tenant_check: true
      )

    # What a pre-fix rotation left behind: the point still on the old key.
    for id <- point_ids(stale) do
      Agent.update(store, fn s ->
        put_in(
          s.points[id],
          Map.merge(s.points[id], %{"type_hmac" => "b2xk", "tags_hmac" => ["b2xk"]})
        )
      end)
    end

    Agent.update(store, &%{&1 | upserts: 0})
    %{user: user, stale: stale, healthy: healthy, store: store}
  end

  test "reports what it checked", ctx do
    ref =
      :telemetry_test.attach_event_handlers(self(), [[:engram, :indexing, :payload_reconcile]])

    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})

    # One event per outcome, all four (`n_points`: points the `n` backfill
    # wrote; `legacy_v3`/`legacy_v3_points`: notes it left for their v3 points).
    counts =
      for _ <- 1..4, into: %{} do
        assert_receive {[:engram, :indexing, :payload_reconcile], ^ref, %{count: n},
                        %{outcome: o}}

        {o, n}
      end

    assert counts == %{
             checked: 2,
             n_points: 0,
             legacy_v3: 0,
             legacy_v3_points: 0
           }
  end

  # The drain probes only `payload_hash IS NULL`; a payload-shape bump is a new
  # ledger version instead (`NotePayloadStamps.version/0` follows
  # `PayloadV6.version/0`), so the runner's pass re-checks every note once.
  # Red before: the version was pinned at 1, the done ledger skipped, and with
  # no daily re-verify the stale-version notes never healed.
  test "a payload_version bump reopens the done ledger and queues the stale notes", ctx do
    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
    assert DataMigrationsRunner.run(NotePayloadStamps) == :done
    v1 = NotePayloadStamps.version()

    Engram.ServiceConfig.put_override(:payload_version, Engram.Indexing.PayloadV6.version() + 1)
    assert NotePayloadStamps.version() == v1 + 1

    assert DataMigrationsRunner.run(NotePayloadStamps) == :more
    assert_enqueued(worker: ReconcileNotePayloads, args: %{"mode" => "n_fleet"})
  end

  test "snoozes while the user's DEK rotation holds the lock", ctx do
    {1, _} =
      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^ctx.user.id),
        [set: [dek_rotation_locked_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

    assert {:snooze, 60} = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
    assert Agent.get(ctx.store, & &1.set_payloads) == []
  end

  # A crashed rotation keeps its lock on purpose; the heal must not write
  # under it, but an hour of it is an operator problem worth one line.
  test "an hour behind a rotation lock warns once and keeps snoozing", ctx do
    {1, _} =
      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^ctx.user.id),
        [set: [dek_rotation_locked_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

    args = %{"user_id" => ctx.user.id}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:snooze, 60} = perform_job(ReconcileNotePayloads, args, meta: %{"snoozed" => 59})
      end)

    refute log =~ "rotation lock held"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:snooze, 60} = perform_job(ReconcileNotePayloads, args, meta: %{"snoozed" => 60})
      end)

    assert log =~ "rotation lock held"
  end

  test "a user with nothing unstamped is done", ctx do
    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
    Agent.update(ctx.store, &%{&1 | set_payloads: []})

    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
    assert Agent.get(ctx.store, & &1.set_payloads) == []
    assert NotePayloadStamps.run_pass() == :done
  end

  # The v5 format on, as prod runs it after the rebuild: `u` is indexed.
  # The v3 cluster: LEGACY_FILTER_FIELDS=false, so the fake has no legacy
  # index and refuses any filter on a legacy key, as v3 would.
  describe "payload version sweep" do
    # Both notes on v5 points written by a real v5 pass, stamped by it. The
    # v3 points are not reused (R3a never rewrites a reused point's payload,
    # so a reused v3 point would stay v3).
    setup ctx do
      vault = Repo.get!(Engram.Vaults.Vault, ctx.stale.vault_id, skip_tenant_check: true)

      Repo.update_all(
        from(c in Chunk, where: c.user_id == ^ctx.user.id),
        [set: [context_hmac: nil]],
        skip_tenant_check: true
      )

      for note <- [ctx.stale, ctx.healthy] do
        {:ok, plain} = Crypto.maybe_decrypt_note_fields(reload(note), ctx.user)
        assert {:ok, _} = Indexing.index_note(plain, vault)
      end

      ids = point_ids(ctx.stale) ++ point_ids(ctx.healthy)
      passed = Agent.get(ctx.store, &Map.take(&1.points, ids))
      assert map_size(passed) == length(ids) and ids != []
      assert reload(ctx.stale).payload_hash && reload(ctx.healthy).payload_hash
      Agent.update(ctx.store, &%{&1 | set_payloads: [], overwrites: [], upserts: 0})
      %{ids: ids, passed: passed}
    end

    defp payload_versions(ctx) do
      Repo.all(
        from(s in NoteIndexState, where: s.user_id == ^ctx.user.id, select: s.payload_version),
        skip_tenant_check: true
      )
    end

    defp no_embed, do: expect(Engram.MockEmbedder, :embed_texts, 0, fn _ -> flunk("embed") end)

    # The state R2 meets: points written before `n` existed, notes stamped
    # by a pass but never with a payload version.
    defp pre_n(ctx) do
      for id <- ctx.ids,
          do: Agent.update(ctx.store, &update_in(&1.points[id], fn p -> Map.delete(p, "n") end))

      null_versions(ctx)
    end

    defp null_versions(ctx) do
      Repo.update_all(
        from(s in NoteIndexState, where: s.user_id == ^ctx.user.id),
        [set: [payload_version: nil]],
        skip_tenant_check: true
      )
    end

    # Any DEK load fails: a path that decrypts errors the job.
    defp no_dek(ctx) do
      {1, _} =
        Repo.update_all(
          from(u in Engram.Accounts.User, where: u.id == ^ctx.user.id),
          [set: [encrypted_dek: nil]],
          skip_tenant_check: true
        )

      Engram.Crypto.DekCache.invalidate_all()
    end

    test "an index pass writes n and stamps the payload version in-pass", ctx do
      assert Enum.all?(ctx.passed, &n_kept?(ctx, &1))
      assert payload_versions(ctx) == [PayloadV6.version(), PayloadV6.version()]
      assert PayloadV6.version() == 6
    end

    test "with the version at the baseline the sweep writes no n", ctx do
      ServiceConfig.put_override(:payload_version, PayloadV6.baseline())
      pre_n(ctx)
      assert queued_users() == 0

      no_embed()
      assert :ok = sweep(ctx)
      assert Agent.get(ctx.store, & &1.batches) == []
      assert payload_versions(ctx) |> Enum.all?(&is_nil/1)
    end

    test "points without n get only n, in one merge batch, with no DEK and no embed", ctx do
      %{ids: ids, passed: passed} = ctx
      pre_n(ctx)
      no_dek(ctx)
      assert queued_users() == 1

      no_embed()
      assert :ok = sweep(ctx)

      # One batch of per-point merges: not an upsert, not a PUT, nothing deleted.
      assert [written] = Agent.get(ctx.store, & &1.batches)
      assert Enum.sort(written) == Enum.sort(ids)
      assert Agent.get(ctx.store, & &1.upserts) == 0
      assert Agent.get(ctx.store, & &1.overwrites) == []
      assert Agent.get(ctx.store, & &1.set_payloads) == []

      # Exactly what an R2 pass writes, and stamped.
      assert Agent.get(ctx.store, &Map.take(&1.points, ids)) == passed
      assert payload_versions(ctx) == [6, 6]

      # Converged: nothing left to select, nothing more written.
      assert queued_users() == 0
      assert :ok = sweep(ctx)
      assert length(Agent.get(ctx.store, & &1.batches)) == 1
    end

    test "points already holding n are not written again", ctx do
      pre_n(ctx)

      for id <- point_ids(ctx.stale),
          do: Agent.update(ctx.store, &put_in(&1.points[id], ctx.passed[id]))

      no_embed()
      assert :ok = sweep(ctx)

      assert [written] = Agent.get(ctx.store, & &1.batches)
      assert Enum.sort(written) == Enum.sort(point_ids(ctx.healthy))
      assert payload_versions(ctx) == [6, 6]
    end

    test "the n backfill only merges: a key it does not own stays", ctx do
      pre_n(ctx)
      id = hd(point_ids(ctx.stale))
      Agent.update(ctx.store, &update_in(&1.points[id], fn p -> Map.put(p, "o", ["kept"]) end))

      no_embed()
      assert :ok = sweep(ctx)

      point = Agent.get(ctx.store, &Map.fetch!(&1.points, id))
      assert point["o"] == ["kept"]
      assert n_kept?(ctx, {id, point})
    end

    test "a note still on legacy points is healed, not stamped with the new version", ctx do
      null_versions(ctx)

      # Back on v3 points, with a hash from an earlier pass.
      for note <- [ctx.stale, ctx.healthy] do
        Engram.LegacyPoints.rekey!(reload(note), ctx.user, ctx.store)
      end

      Agent.update(ctx.store, &%{&1 | batches: []})
      assert queued_users() == 1

      no_embed()
      assert :ok = sweep(ctx)

      # A v3 point never gets `n`.
      assert Agent.get(ctx.store, & &1.batches) == []
      assert Enum.all?(payload_versions(ctx), &is_nil/1)
      # Still in view of the sweep: nothing claims the new shape was written.
      assert queued_users() == 1
    end

    test "points already holding the payload are only stamped", ctx do
      null_versions(ctx)
      no_embed()
      assert :ok = sweep(ctx)

      assert Agent.get(ctx.store, & &1.batches) == []
      assert payload_versions(ctx) == [6, 6]
    end

    # A newer release stamps `n`; the expected payload is compared without
    # the identity keys, so a point holding it is not drifted and no refresh
    # deletes it (a rolling deploy or a rollback would strip it otherwise).
    test "a point holding n is neither drifted nor stripped of n", ctx do
      null_versions(ctx)

      no_embed()
      assert :ok = sweep(ctx)

      assert Agent.get(ctx.store, & &1.batches) == []
      assert Enum.all?(Agent.get(ctx.store, &Map.take(&1.points, ctx.ids)), &n_kept?(ctx, &1))
    end

    # The version stamp's refresh is `n` only: the note's hash vouches for
    # the rest, so it costs no decrypt (the drift heal is NULL-hash only).
    test "a stamped note behind the version is neither decrypted nor drift-checked", ctx do
      null_versions(ctx)
      no_dek(ctx)
      id = hd(point_ids(ctx.stale))
      Agent.update(ctx.store, &update_in(&1.points[id], fn p -> Map.put(p, "o", ["kept"]) end))

      no_embed()
      assert :ok = sweep(ctx)

      assert Agent.get(ctx.store, & &1.batches) == []
      assert Agent.get(ctx.store, &Map.fetch!(&1.points, id))["o"] == ["kept"]
      assert payload_versions(ctx) == [6, 6]
    end

    # A previous-release node upserts a point without `n` after its note was
    # stamped (a rolling deploy): the pass is not done until it is healed.
    test "a live point without n keeps the pass open and requeues its user", ctx do
      assert :ok = sweep(ctx)
      assert NotePayloadStamps.run_pass() == :done

      id = hd(point_ids(ctx.stale))
      Agent.update(ctx.store, &update_in(&1.points[id], fn p -> Map.delete(p, "n") end))

      assert {:more, users: 1} = NotePayloadStamps.run_pass()
      assert nil in payload_versions(ctx)

      assert :ok = sweep(ctx)
      assert n_kept?(ctx, {id, Agent.get(ctx.store, &Map.fetch!(&1.points, id))})
      assert NotePayloadStamps.run_pass() == :done
    end

    # A full page of orphans ahead of a live point: the walk must move past
    # them (its offset persists across passes), or the pass never sees the
    # live point and never closes.
    test "a page of orphans does not hide a live point without n", ctx do
      assert :ok = sweep(ctx)
      assert NotePayloadStamps.run_pass() == :done

      for i <- 1..256 do
        orphan = "00000000-0000-4000-8000-" <> String.pad_leading("#{i}", 12, "0")
        Agent.update(ctx.store, &put_in(&1.points[orphan], %{"u" => FilterId.uuid(ctx.user.id)}))
      end

      id = hd(point_ids(ctx.stale))
      Agent.update(ctx.store, &update_in(&1.points[id], fn p -> Map.delete(p, "n") end))

      # One page a pass (`pages: 1`): the orphans, then the live point.
      assert {:more, users: 0} = NotePayloadStamps.run_pass(pages: 1)
      assert {:more, users: 1} = NotePayloadStamps.run_pass(pages: 1)
      assert nil in payload_versions(ctx)

      assert :ok = sweep(ctx)
      # A fresh walk, start to end, finds only orphans: done.
      assert NotePayloadStamps.run_pass() == :done
    end

    # A previous-release node re-upserts a note without `n` after the batch
    # read (its pass NULLs then re-stamps the hash): the version stamp of a
    # stamped-but-behind note must not vouch for it.
    test "a stale note whose hash changed after the read is not version-stamped", ctx do
      pre_n(ctx)
      no_embed()

      Agent.update(ctx.store, fn s ->
        hook = fn ->
          Repo.update_all(
            from(n in Note, where: n.id == ^ctx.stale.id),
            [set: [payload_hash: :crypto.strong_rand_bytes(32)]],
            skip_tenant_check: true
          )
        end

        %{s | on_scroll: hook}
      end)

      assert :ok = sweep(ctx)

      versions =
        Repo.all(
          from(s in NoteIndexState,
            where: s.user_id == ^ctx.user.id,
            select: {s.note_id, s.payload_version}
          ),
          skip_tenant_check: true
        )
        |> Map.new()

      assert versions[ctx.stale.id] == nil
      assert versions[ctx.healthy.id] == 6
    end

    defp orphans!(ctx, count) do
      for i <- 1..count do
        orphan = "00000000-0000-4000-8000-" <> String.pad_leading("#{i}", 12, "0")
        Agent.update(ctx.store, &put_in(&1.points[orphan], %{"u" => FilterId.uuid(ctx.user.id)}))
      end
    end

    defp old_cluster do
      old = :"old@10.0.0.9"

      [
        peers: fn -> [old] end,
        multicall: fn nodes ->
          Enum.map(
            nodes,
            &if(&1 == old, do: {:ok, Engram.Indexing.PayloadV6.baseline()}, else: {:ok, 6})
          )
        end
      ]
    end

    # The fleet ledger is cached for good once done: a walk that began while
    # an older node could still write points without `n` proves nothing.
    test "the ledger never closes on a walk that began with an old node present", ctx do
      assert :ok = sweep(ctx)

      # One-page walk, old node present at its start.
      refute NotePayloadStamps.run_pass(old_cluster()) == :done

      # Two-page walk: begun with the old node, finished without it.
      orphans!(ctx, 257)
      refute NotePayloadStamps.run_pass([pages: 1] ++ old_cluster()) == :done

      refute NotePayloadStamps.run_pass(pages: 1, role: nil, query: nil, peers: fn -> [] end) ==
               :done

      # The next walk, every node new from its start: done.
      refute NotePayloadStamps.run_pass(pages: 1, role: nil, query: nil, peers: fn -> [] end) ==
               :done

      assert NotePayloadStamps.run_pass(pages: 1, role: nil, query: nil, peers: fn -> [] end) ==
               :done
    end

    # Rollback then roll-forward: the older release re-upserted a note's
    # points without `n` while the ledger was done (cached for good) and the
    # stamp stayed 6. No operator step: the daily re-verify finds the points,
    # reopens the ledger and requeues the user; the next chain heals them.
    test "a rollback's points without n reopen the done ledger by themselves", ctx do
      assert :ok = sweep(ctx)
      DataMigrations.mark_done(NotePayloadStamps.name(), NotePayloadStamps.version())
      assert DataMigrations.done?(NotePayloadStamps.name(), NotePayloadStamps.version())

      # A clean re-verify stays done.
      assert DataMigrationsRunner.run(NotePayloadStamps, true) == :done

      id = hd(point_ids(ctx.stale))
      Agent.update(ctx.store, &update_in(&1.points[id], fn p -> Map.delete(p, "n") end))
      assert payload_versions(ctx) == [6, 6]

      assert DataMigrationsRunner.run(NotePayloadStamps, true) == :more
      refute DataMigrations.done?(NotePayloadStamps.name(), NotePayloadStamps.version())
      assert nil in payload_versions(ctx)
      assert_enqueued(worker: ReconcileNotePayloads, args: %{"mode" => "n_fleet"})

      assert :ok = sweep(ctx)
      assert n_kept?(ctx, {id, Agent.get(ctx.store, &Map.fetch!(&1.points, id))})
    end

    # The edit path vouches for the version only for points it wrote with
    # the payload (which holds `n`): an edit that reuses chunk points it did
    # not rewrite (the payload unchanged) leaves the version, so the `n`
    # backfill still reaches them.
    test "an edit that reuses chunks lacking n does not stamp the version", ctx do
      pre_n(ctx)
      vault = Repo.get!(Engram.Vaults.Vault, ctx.stale.vault_id, skip_tenant_check: true)
      {:ok, plain} = Crypto.maybe_decrypt_note_fields(reload(ctx.stale), ctx.user)

      assert {:ok, _} = Indexing.index_note(plain, vault)

      assert Enum.all?(
               point_ids(ctx.stale),
               &(not Map.has_key?(Agent.get(ctx.store, fn s -> s.points[&1] end), "n"))
             )

      assert Enum.all?(payload_versions(ctx), &is_nil/1)
    end

    # `n` jobs sort behind heals on the one `crdt_backfill` lane: a heal
    # inserted after a minute's worth of `n` wakes still goes first.
    test "the fleet n job runs at the heal's priority (3), so neither starves the other" do
      heal = ReconcileNotePayloads.new(%{"user_id" => Ecto.UUID.generate()})
      n = ReconcileNotePayloads.new(%{"mode" => "n_fleet"})

      assert Ecto.Changeset.get_field(n, :priority) == 3
      assert Ecto.Changeset.get_field(n, :priority) == Ecto.Changeset.get_field(heal, :priority)
    end

    # A heal stream on the one lane must not hold the fleet job back: an
    # executing heal for this user neither blocks the fleet enqueue nor
    # absorbs it (separate unique slots).
    test "a running heal job does not stop the window from queueing the fleet n job", ctx do
      pre_n(ctx)

      {:ok, heal} = Oban.insert(ReconcileNotePayloads.new(%{"user_id" => ctx.user.id}))

      Repo.update_all(from(j in Oban.Job, where: j.id == ^heal.id),
        set: [state: "executing", attempted_at: DateTime.utc_now()]
      )

      assert queued_users() > 0
      assert_enqueued(worker: ReconcileNotePayloads, args: %{"mode" => "n_fleet"})
      assert Repo.get!(Oban.Job, heal.id).args == %{"user_id" => ctx.user.id, "mode" => "heal"}
    end

    # The walk's `fresh` flag is re-checked on every call, not only at its
    # start: an older node that joins mid-walk can write points without `n`
    # behind the cursor, so that walk must never close the ledger.
    test "a walk begun fresh that an old node joins mid-walk never closes the ledger", ctx do
      assert :ok = sweep(ctx)
      orphans!(ctx, 257)
      new = [role: nil, query: nil, peers: fn -> [] end]

      refute NotePayloadStamps.run_pass([pages: 1] ++ new) == :done
      refute NotePayloadStamps.run_pass([pages: 1] ++ old_cluster()) == :done

      # The next walk, every node new from its start: done.
      refute NotePayloadStamps.run_pass([pages: 1] ++ new) == :done
      assert NotePayloadStamps.run_pass([pages: 1] ++ new) == :done
    end

    # The heal and the `n` backfill are separate jobs with separate unique
    # slots: a paused backfill chain (scheduled, mid-cursor) must not swallow
    # a DEK rotation's heal, which heals from the user's first note.
    test "a paused n job does not swallow a DEK rotation's heal", ctx do
      top = Enum.max([ctx.stale.id, ctx.healthy.id])

      {:ok, paused} =
        Oban.insert(
          ReconcileNotePayloads.new(%{"user_id" => ctx.user.id, "mode" => "n", "after" => top},
            schedule_in: 600
          )
        )

      # What the rotation's flip does: every stamp NULLed, a heal queued.
      {2, _} =
        Repo.update_all(
          from(n in Note, where: n.user_id == ^ctx.user.id),
          [set: [payload_hash: nil, keyword_version: nil]],
          skip_tenant_check: true
        )

      {:ok, heal} = Oban.insert(ReconcileNotePayloads.new(%{"user_id" => ctx.user.id}))
      refute heal.conflict?
      refute heal.id == paused.id

      no_embed()
      assert :ok = perform_job(ReconcileNotePayloads, heal.args)
      assert reload(ctx.stale).payload_hash && reload(ctx.healthy).payload_hash
    end

    # A failed `n` write is the backfill job's alone: the heal job never
    # writes `n`, so its HMAC rewrite cannot be cancelled by one.
    test "an n write failure leaves the heal unaffected", ctx do
      pre_n(ctx)

      for id <- point_ids(ctx.stale),
          do:
            Agent.update(
              ctx.store,
              &update_in(&1.points[id], fn p -> Map.put(p, "y", "b2xk") end)
            )

      {2, _} =
        Repo.update_all(
          from(n in Note, where: n.user_id == ^ctx.user.id),
          [set: [payload_hash: nil, keyword_version: nil]],
          skip_tenant_check: true
        )

      Agent.update(ctx.store, &%{&1 | batch_status: 422})
      no_embed()

      assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})

      # The heal stamps the row and writes no point (R3a).
      for id <- point_ids(ctx.stale),
          do: assert(Agent.get(ctx.store, &Map.fetch!(&1.points, id))["y"] == "b2xk")

      assert reload(ctx.stale).payload_hash && reload(ctx.healthy).payload_hash
      # The fleet job logs and counts the refusal and carries on past the user.
      assert :ok = n_job(ctx)
      assert reload(ctx.stale).payload_hash
    end

    # The hourly pass must not run an unindexed "any note behind?" EXISTS
    # per user (it reads every note when the answer is no): it walks the
    # notes primary key in fixed windows (`Engram.Backfill.IdWindows`), and
    # the stale predicate only ever sees one window's ids.
    test "the ledger pass finds stale notes by id windows, never a per-user scan", ctx do
      null_versions(ctx)

      {result, queries} =
        Engram.QueryRecorder.record(fn ->
          NotePayloadStamps.run_pass(role: nil, query: nil, peers: fn -> [] end)
        end)

      assert {:more, _} = result
      stale = for q <- queries, q.pid == self(), q.sql =~ "payload_version", do: q.sql
      assert stale != []
      assert Enum.all?(stale, &(&1 =~ "unnest"))
      assert_enqueued(worker: ReconcileNotePayloads, args: %{"mode" => "n_fleet"})
    end

    # A just-booted node in a rolling deploy, not yet joined to the old ones:
    # `Node.list/0` is empty, but discovery still lists them. Not a fresh walk.
    test "a walk begun before this node joined the cluster never closes the ledger", ctx do
      assert :ok = sweep(ctx)

      alone = [
        role: "app",
        query: "engram.internal",
        resolver: fn _ -> ["10.0.0.1", "10.0.0.2"] end,
        self_ip: "10.0.0.1",
        peers: fn -> [] end
      ]

      refute NotePayloadStamps.run_pass(alone) == :done
      assert NotePayloadStamps.run_pass(role: nil, query: nil, peers: fn -> [] end) == :done
    end

    # A walk cursor the previous release saved has an offset but no "fresh":
    # nothing proves the cluster wrote `n` when that walk began.
    test "a walk resumed from an old release's cursor never closes the ledger", ctx do
      assert :ok = sweep(ctx)

      :ok =
        Engram.Maintenance.Cursor.put("payload_n_requeue", %{
          "offset" => "ffffffff-ffff-4fff-bfff-ffffffffffff",
          "dirty" => false
        })

      refute NotePayloadStamps.run_pass(role: nil, query: nil, peers: fn -> [] end) == :done
      # The next walk re-checks the cluster from its start: done.
      assert NotePayloadStamps.run_pass(role: nil, query: nil, peers: fn -> [] end) == :done
    end

    test "an orphan point without n (no chunk row) does not hold the pass open", ctx do
      orphan = Ecto.UUID.generate()
      Agent.update(ctx.store, &put_in(&1.points[orphan], %{"u" => FilterId.uuid(ctx.user.id)}))

      assert NotePayloadStamps.run_pass() == :done
    end

    defp n_kept?(ctx, {id, point}) do
      note = if id in point_ids(ctx.stale), do: ctx.stale, else: ctx.healthy
      point["n"] == FilterId.uuid(note.id)
    end

    test "a newer stamp is current: a rollback selects nothing", ctx do
      ServiceConfig.put_override(:payload_version, PayloadV6.baseline() + 1)

      {2, _} =
        Repo.update_all(
          from(s in NoteIndexState, where: s.user_id == ^ctx.user.id),
          [set: [payload_version: PayloadV6.baseline() + 1]],
          skip_tenant_check: true
        )

      assert queued_users() == 0
      # And back on the baseline code, the newer stamp is still not behind.
      ServiceConfig.put_override(:payload_version, PayloadV6.baseline())
      assert queued_users() == 0
    end
  end

  # The ledger's done also needs the collection's `n` index: search filters
  # on `n`, and a done ledger is cached for good.
  describe "the n index in the ledger's done" do
    setup ctx do
      assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
      assert NotePayloadStamps.run_pass() == :done
      DataMigrations.reopen(NotePayloadStamps.name(), NotePayloadStamps.version())
      :ok
    end

    defp no_n_index(ctx), do: Agent.update(ctx.store, &%{&1 | schema: %{"u" => %{}}})

    test "clean walks and no n index: more, the ledger stays open, the index is ensured",
         ctx do
      no_n_index(ctx)
      test_pid = self()
      ensure = fn -> send(test_pid, :ensured) && :ok end

      assert {:more, n_index_missing: 1} = NotePayloadStamps.run_pass(ensure_collection: ensure)
      assert_received :ensured
      refute NotePayloadStamps.done?()
    end

    test "clean walks and the n index present: done", _ctx do
      assert NotePayloadStamps.run_pass() == :done
    end

    test "a done ledger whose n index went missing reopens at re-verify, cache erased", ctx do
      assert DataMigrationsRunner.run(NotePayloadStamps) == :done
      assert NotePayloadStamps.done?()
      no_n_index(ctx)

      assert DataMigrationsRunner.run(NotePayloadStamps, true) == :more
      refute NotePayloadStamps.done?()
    end

    test "an unreadable schema keeps a done ledger done and an open one open", ctx do
      Agent.update(ctx.store, &%{&1 | schema: nil})
      refute NotePayloadStamps.run_pass() == :done

      DataMigrations.mark_done(NotePayloadStamps.name(), NotePayloadStamps.version())
      assert NotePayloadStamps.run_pass() == :done
    end
  end

  describe "the heal (R3a)" do
    # The hash an index pass stamps: of the identity payload, the same for
    # every point of the note.
    defp identity_hash(note) do
      payload = %{
        "u" => FilterId.uuid(note.user_id),
        "v" => FilterId.uuid(note.vault_id),
        "n" => FilterId.uuid(note.id)
      }

      :crypto.hash(:sha256, :erlang.term_to_binary(payload, [:deterministic]))
    end

    test "stamps the identity hash on NULL rows with no Qdrant call and no decrypt", ctx do
      expect(Engram.MockEmbedder, :embed_texts, 0, fn _ -> flunk("embed during heal") end)
      Agent.update(ctx.store, &%{&1 | requests: []})

      assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})

      assert Agent.get(ctx.store, & &1.requests) == []
      assert reload(ctx.stale).payload_hash == identity_hash(ctx.stale)
      assert reload(ctx.healthy).payload_hash == identity_hash(ctx.healthy)
    end

    test "leaves a stamped row alone", ctx do
      kept = :crypto.strong_rand_bytes(32)

      Repo.update_all(
        from(n in Note, where: n.id == ^ctx.healthy.id),
        [set: [payload_hash: kept]],
        skip_tenant_check: true
      )

      assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
      assert reload(ctx.healthy).payload_hash == kept
      assert reload(ctx.stale).payload_hash == identity_hash(ctx.stale)
    end
  end

  # What one whole walk of the ledger's id windows queues
  # (`ReconcileNotePayloads.queue_window/2`): users with a note to heal.
  defp queued_users do
    {:ok, queued} =
      Engram.Backfill.IdWindows.reduce_all(Note, 0, fn ids, ctx, acc ->
        {n, false} = ReconcileNotePayloads.queue_window(ids, ctx)
        {:cont, acc + n}
      end)

    queued
  end

  # What the ledger queues for a user: the heal (no mode) and the `n`
  # backfill (the fleet job), each its own job. The heal's result is returned
  # when it fails, else the backfill's.
  defp sweep(ctx) do
    case perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id}) do
      :ok -> n_job(ctx)
      other -> other
    end
  end

  # The fleet `n` job walks every user, the context's among them.
  defp n_job(_ctx), do: perform_job(ReconcileNotePayloads, %{"mode" => "n_fleet"})

  defp reload(note),
    do: Engram.Fixtures.raw_note!(note.id)

  defp point_ids(note) do
    Repo.all(from(c in Chunk, where: c.note_id == ^note.id, select: c.qdrant_point_id),
      skip_tenant_check: true
    )
  end

  defp fake_qdrant(conn, store) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
    Agent.update(store, &%{&1 | requests: [{conn.method, conn.request_path} | &1.requests]})
    body = if body == "", do: %{}, else: Jason.decode!(body)
    status = Agent.get(store, & &1.payload_status)
    scroll_status = Agent.get(store, & &1.scroll_status)
    scroll? = String.ends_with?(conn.request_path, "/points/scroll")

    batch_status = Agent.get(store, & &1.batch_status)

    cond do
      status != 200 and String.ends_with?(conn.request_path, "/points/payload") ->
        Plug.Conn.send_resp(conn, status, "{}")

      # The `n` backfill's write (`Qdrant.set_payloads/2`).
      batch_status != nil and String.ends_with?(conn.request_path, "/points/batch") ->
        Plug.Conn.send_resp(conn, batch_status, "{}")

      scroll? and scroll_status != nil ->
        Plug.Conn.send_resp(conn, scroll_status, "{}")

      scroll? and
          unindexed(body["filter"], Agent.get(store, & &1.legacy_indexes)) !=
            [] ->
        # Qdrant Cloud strict mode, `unindexed_filtering_retrieve: false`.
        Plug.Conn.send_resp(conn, 400, ~s({"status":{"error":"Bad request: Index required"}}))

      true ->
        fake_reply(conn, store, body)
    end
  end

  defp unindexed(filter, legacy?) do
    indexed = for {key, _} <- QdrantLayout.payload_indexes(nil, legacy?), do: key
    filter |> filter_keys() |> Enum.reject(&(&1 in indexed))
  end

  defp filter_keys(%{"key" => key}), do: [key]
  defp filter_keys(%{"is_empty" => %{"key" => key}}), do: [key]
  defp filter_keys(%{"is_null" => %{"key" => key}}), do: [key]

  defp filter_keys(%{} = filter),
    do: for(k <- ~w(must should must_not), c <- filter[k] || [], key <- filter_keys(c), do: key)

  defp filter?(id, payload, filter) do
    Enum.all?(filter["must"] || [], &condition?(id, payload, &1)) and
      (Map.get(filter, "should", []) == [] or
         Enum.any?(filter["should"], &condition?(id, payload, &1))) and
      not Enum.any?(filter["must_not"] || [], &condition?(id, payload, &1))
  end

  defp condition?(id, _payload, %{"has_id" => ids}), do: id in ids
  defp condition?(_id, payload, %{"key" => k, "match" => %{"value" => v}}), do: payload[k] == v
  defp condition?(_id, payload, %{"is_empty" => %{"key" => k}}), do: payload[k] in [nil, []]
  defp condition?(id, payload, nested), do: filter?(id, payload, nested)

  defp fake_reply(conn, store, body) do
    result =
      case {conn.method, conn.request_path} do
        {"PUT", "/collections/engram_notes/points"} ->
          if hook = Agent.get(store, & &1.on_upsert), do: hook.()

          Agent.update(store, fn s ->
            points = Map.new(body["points"], &{&1["id"], &1["payload"]})
            %{s | points: Map.merge(s.points, points), upserts: s.upserts + 1}
          end)

          %{"status" => "completed"}

        {"POST", "/collections/engram_notes/points/payload"} ->
          if hook = Agent.get(store, & &1.on_write), do: hook.()

          ids = for %{"has_id" => ids} <- body["filter"]["should"], id <- ids, do: id

          Agent.update(store, fn s ->
            points =
              Enum.reduce(ids, s.points, fn id, acc ->
                Map.update(acc, id, body["payload"], &Map.merge(&1, body["payload"]))
              end)

            %{s | points: points, set_payloads: [ids | s.set_payloads]}
          end)

          %{"status" => "completed"}

        # An overwrite is a merge (recorded above) plus this delete of the keys
        # the new payload omits: the delete turns that merge into an overwrite.
        # `Qdrant.set_payloads/3` ends with a barrier delete (`points:`, a key no
        # point has): it changes nothing and is not an overwrite.
        {"POST", "/collections/engram_notes/points/payload/delete"}
        when is_map_key(body, "points") ->
          %{"status" => "completed"}

        {"POST", "/collections/engram_notes/points/payload/delete"} ->
          if hook = Agent.get(store, & &1.on_write), do: hook.()

          ids = for %{"has_id" => ids} <- body["filter"]["should"], id <- ids, do: id

          Agent.update(store, fn s ->
            points =
              Enum.reduce(ids, s.points, fn id, acc ->
                Map.update(acc, id, %{}, &Map.drop(&1, body["keys"]))
              end)

            %{
              s
              | points: points,
                set_payloads: List.delete(s.set_payloads, ids),
                overwrites: [ids | s.overwrites]
            }
          end)

          %{"status" => "completed"}

        # `Qdrant.set_payloads/2`: one unwaited batch of per-point set_payload
        # ops, then (below) a read-back of the keys it set.
        {"POST", "/collections/engram_notes/points/batch"} ->
          ops = body["operations"]

          Agent.update(store, fn s ->
            points =
              Enum.reduce(ops, s.points, fn
                %{"set_payload" => %{"points" => [id], "payload" => pl}}, acc ->
                  Map.update(acc, id, pl, &Map.merge(&1, pl))

                %{"delete_payload" => %{"points" => [id], "keys" => keys}}, acc ->
                  Map.update(acc, id, %{}, &Map.drop(&1, keys))
              end)

            ids =
              Enum.flat_map(ops, fn op -> op |> Map.values() |> Enum.flat_map(& &1["points"]) end)

            %{s | points: points, batches: [Enum.uniq(ids) | s.batches]}
          end)

          Enum.map(ops, fn _ -> %{"status" => "completed"} end)

        {"POST", "/collections/engram_notes/points"} ->
          points = Agent.get(store, & &1.points)

          for id <- body["ids"], Map.has_key?(points, id) do
            %{"id" => id, "payload" => Map.take(points[id], body["with_payload"])}
          end

        {"POST", "/collections/engram_notes/points/scroll"} ->
          fake_scroll(store, body)

        _other ->
          true
      end

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => result, "status" => "ok"}))
  end

  defp fake_scroll(store, body) do
    if hook = Agent.get(store, & &1.on_scroll), do: hook.()

    # The whole filter is evaluated, as Qdrant would: a heal whose
    # filter hides a point layout must not pass here by accident.
    # By id, or the done check's v5 points without `n` (every key indexed).
    filter = body["filter"]

    assert Enum.any?(filter["must"] || [], &Map.has_key?(&1, "has_id")) or
             filter["must"] == [%{"is_empty" => %{"key" => "n"}}]

    # Paged as Qdrant pages: id order, from `offset`, `limit` points,
    # and the next id as `next_page_offset`.
    matching =
      for(
        {id, payload} <- Enum.sort(Agent.get(store, & &1.points)),
        filter?(id, payload, filter),
        body["offset"] == nil or id >= body["offset"],
        do: %{"id" => id, "payload" => Map.take(payload, body["with_payload"])}
      )

    {page, rest} = Enum.split(matching, body["limit"] || length(matching))
    %{"points" => page, "next_page_offset" => if(rest == [], do: nil, else: hd(rest)["id"])}
  end
end
