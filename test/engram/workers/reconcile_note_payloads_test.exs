defmodule Engram.Workers.ReconcileNotePayloadsTest do
  @moduledoc """
  Self-heal for users a DEK rotation already hit: their rows were rekeyed but
  every point kept the old filter HMACs. The reconcile reads the points,
  rewrites only the drifted ones with `set_payload` (no upsert, no embed) and
  stamps every checked note so the migration converges.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]
  import Mox

  alias Engram.Crypto
  alias Engram.DataMigrations.NotePayloadStamps
  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.{Chunk, Note}
  alias Engram.Vector.{FilterId, QdrantLayout}
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
          on_scroll: nil,
          on_write: nil,
          on_upsert: nil,
          payload_status: 200,
          scroll_status: nil,
          v5_indexes: false,
          legacy_indexes: true
        }
      end)

    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    Bypass.stub(bypass, :any, :any, &fake_qdrant(&1, store))

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

  test "rewrites only the drifted points, without re-embedding, and converges", ctx do
    expect(Engram.MockEmbedder, :embed_texts, 0, fn _ -> flunk("embed during reconcile") end)

    assert {:more, users: 1} = NotePayloadStamps.run_pass()
    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})

    raw = reload(ctx.stale)
    want = Indexing.expected_note_payload(raw) |> Jason.encode!() |> Jason.decode!()

    for id <- point_ids(ctx.stale) do
      point = Agent.get(ctx.store, &Map.fetch!(&1.points, id))
      assert point["type_hmac"] == want["type_hmac"]
      assert point["tags_hmac"] == want["tags_hmac"]
    end

    # One set_payload, for the drifted note only; the healthy one is just stamped.
    assert [ids] = Agent.get(ctx.store, & &1.set_payloads)
    assert Enum.sort(ids) == Enum.sort(point_ids(ctx.stale))
    assert Agent.get(ctx.store, & &1.upserts) == 0

    assert reload(ctx.stale).payload_hash
    assert reload(ctx.healthy).payload_hash
    # Drifted filter keys mean a rotation, so its sparse vectors are stale too.
    assert reload(ctx.stale).keyword_version == nil
    refute reload(ctx.healthy).keyword_version == nil
    assert NotePayloadStamps.run_pass() == :done
  end

  test "reports what it checked and rewrote", ctx do
    ref =
      :telemetry_test.attach_event_handlers(self(), [[:engram, :indexing, :payload_reconcile]])

    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})

    counts =
      for _ <- 1..4, into: %{} do
        assert_receive {[:engram, :indexing, :payload_reconcile], ^ref, %{count: n},
                        %{outcome: o}}

        {o, n}
      end

    assert counts == %{checked: 2, drifted: 1, rewritten: 1, skipped_v5: 0}
  end

  # #2087's short-key layout. Healed with the v5 payload, REPLACED (a v3
  # merge would leave the layouts mixed), and stamped with its hash. Before
  # #2067 this note was skipped and left unstamped, so a rotation left every
  # v5 point on the retired key for good.
  # `want` is what a real v5 index pass wrote, never `expected_v5_payload/2`
  # (the function under test): drift between the heal and the pass, or an
  # overwrite that drops a key the pass writes, fails here.
  test "a v5-shaped point is replaced with exactly what a v5 pass writes", ctx do
    v5_on(ctx)
    vault = Repo.get!(Engram.Vaults.Vault, ctx.stale.vault_id, skip_tenant_check: true)
    {:ok, plain} = Crypto.maybe_decrypt_note_fields(reload(ctx.stale), ctx.user)
    assert {:ok, _} = Indexing.index_note(plain, vault)

    ids = point_ids(ctx.stale)
    passed = Agent.get(ctx.store, &Map.take(&1.points, ids))
    assert map_size(passed) == length(ids) and ids != []
    pass_hash = reload(ctx.stale).payload_hash
    Agent.update(ctx.store, &%{&1 | overwrites: []})

    # A rotation left the points on the retired key, and the stamp NULL.
    for id <- ids,
        do: Agent.update(ctx.store, &put_in(&1.points[id], retired_v5(ctx)))

    {1, _} =
      Repo.update_all(from(n in Note, where: n.id == ^ctx.stale.id), [set: [payload_hash: nil]],
        skip_tenant_check: true
      )

    expect(Engram.MockEmbedder, :embed_texts, 0, fn _ -> flunk("embed during reconcile") end)
    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})

    assert [written] = Agent.get(ctx.store, & &1.overwrites)
    assert Enum.sort(written) == Enum.sort(ids)
    assert Agent.get(ctx.store, &Map.take(&1.points, ids)) == passed

    assert Agent.get(ctx.store, & &1.set_payloads) == []
    assert reload(ctx.stale).payload_hash == pass_hash
    assert reload(ctx.healthy).payload_hash
  end

  # An index commits (and stamps its own payload) after the heal read the
  # row and before its write lands: the heal's write may have replaced the
  # fresher payload, so the row must not keep a stamp that vouches for it.
  test "a write that lost the race to an index leaves the row unstamped", ctx do
    stale_id = ctx.stale.id

    Agent.update(ctx.store, fn s ->
      %{
        s
        | on_write: fn ->
            Repo.update_all(
              from(n in Note, where: n.id == ^stale_id),
              [set: [content_hash: "edited", payload_hash: "stamped-by-the-index"]],
              skip_tenant_check: true
            )
          end
      }
    end)

    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
    assert [_] = Agent.get(ctx.store, & &1.set_payloads)
    assert reload(ctx.stale).payload_hash == nil
    assert reload(ctx.healthy).payload_hash
  end

  # An EmbedNote commit between the heal's read and its stamp: stamping the
  # hash read before it would vouch for HMACs the row no longer holds.
  test "a row that moved under the heal is left unstamped", ctx do
    stale_id = ctx.stale.id

    Agent.update(ctx.store, fn s ->
      %{
        s
        | on_scroll: fn ->
            Repo.update_all(
              from(n in Note, where: n.id == ^stale_id),
              [set: [tags_hmac: [<<1, 2, 3>>]]],
              skip_tenant_check: true
            )
          end
      }
    end)

    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
    assert reload(ctx.stale).payload_hash == nil
    assert reload(ctx.healthy).payload_hash
  end

  # The same race on the index pass: it PATCHes its reused points, then an
  # edit commits (and stamps) first and the pass rolls back superseded. Its
  # PATCH may have replaced the edit's payload, so the row is unstamped.
  test "a pass superseded after refreshing reused points leaves the row unstamped", ctx do
    id = ctx.healthy.id

    Agent.update(ctx.store, fn s ->
      %{
        s
        | on_write: fn ->
            Repo.update_all(
              from(n in Note, where: n.id == ^id),
              [set: [content_hash: "edited", payload_hash: "stamped-by-the-edit"]],
              skip_tenant_check: true
            )
          end
      }
    end)

    vault = Repo.get!(Engram.Vaults.Vault, ctx.healthy.vault_id, skip_tenant_check: true)
    {:ok, plain} = Crypto.maybe_decrypt_note_fields(reload(ctx.healthy), ctx.user)

    assert {:error, :superseded} = Indexing.index_note(plain, vault)
    assert [_] = Agent.get(ctx.store, & &1.set_payloads)
    assert reload(ctx.healthy).payload_hash == nil
  end

  # Under the v5 layout point ids are deterministic, so a losing pass can
  # UPSERT over the very points the winning pass wrote (not only PATCH
  # reused ones). Those points then hold the older filter fields.
  test "a superseded v5 pass that upserted points leaves the row unstamped", ctx do
    Engram.ServiceConfig.put_override(:write_v5_layout, true)
    vault = Repo.get!(Engram.Vaults.Vault, ctx.healthy.vault_id, skip_tenant_check: true)

    # Never indexed, so the pass embeds and upserts every point.
    {:ok, note} =
      Notes.upsert_note(
        ctx.user,
        vault,
        %{"path" => "Ops/Fresh.md", "content" => "---\ntype: Runbook\n---\n# F\n\nNew.\n"},
        actor: "api"
      )

    id = note.id

    Agent.update(ctx.store, fn s ->
      %{
        s
        | on_upsert: fn ->
            Repo.update_all(
              from(n in Note, where: n.id == ^id),
              [set: [content_hash: "edited", payload_hash: "stamped-by-the-edit"]],
              skip_tenant_check: true
            )
          end
      }
    end)

    {:ok, plain} = Crypto.maybe_decrypt_note_fields(reload(note), ctx.user)

    assert {:error, :superseded} = Indexing.index_note(plain, vault)
    assert reload(note).payload_hash == nil
  end

  # The v3 index set has no legacy index: a legacy key in the heal scroll 400s.
  test "on the v3 cluster the heal filters on v5 keys only (no strict 400)", ctx do
    v3_on(ctx)

    for id <- point_ids(ctx.stale),
        do: Agent.update(ctx.store, &put_in(&1.points[id], retired_v5(ctx)))

    {1, _} =
      Repo.update_all(
        from(n in Note, where: n.id == ^ctx.stale.id),
        [set: [content_ciphertext: :crypto.strong_rand_bytes(48)]],
        skip_tenant_check: true
      )

    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
    assert reload(ctx.stale).payload_hash == ReconcileNotePayloads.undecryptable_stamp()
  end

  # A v5 note whose row no longer decrypts cannot be healed. Left NULL, the
  # daily re-check would requeue its user forever; it is marked (never
  # deleted), counted, and skipped by the re-check until a pass rewrites it.
  test "an undecryptable v5 note is marked, counted, and not re-picked", ctx do
    v5_on(ctx)

    for id <- point_ids(ctx.stale),
        do: Agent.update(ctx.store, &put_in(&1.points[id], retired_v5(ctx)))

    {1, _} =
      Repo.update_all(
        from(n in Note, where: n.id == ^ctx.stale.id),
        [set: [content_ciphertext: :crypto.strong_rand_bytes(48)]],
        skip_tenant_check: true
      )

    ref =
      :telemetry_test.attach_event_handlers(self(), [[:engram, :indexing, :payload_reconcile]])

    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})

    assert_receive {[:engram, :indexing, :payload_reconcile], ^ref, %{count: 1},
                    %{outcome: :skipped_v5}}

    assert reload(ctx.stale).payload_hash == ReconcileNotePayloads.undecryptable_stamp()
    assert Repo.exists?(from(n in Note, where: n.id == ^ctx.stale.id), skip_tenant_check: true)
    assert Agent.get(ctx.store, & &1.overwrites) == []
    assert NotePayloadStamps.run_pass() == :done
  end

  # A key-provider or DEK-load failure is not "this note is undecryptable":
  # the note stays NULL (the daily re-check still covers it) and the job
  # fails so Oban backs off.
  test "a transient key failure marks nothing and fails the job", ctx do
    v5_on(ctx)

    for id <- point_ids(ctx.stale),
        do: Agent.update(ctx.store, &put_in(&1.points[id], retired_v5(ctx)))

    {1, _} =
      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^ctx.user.id),
        [set: [encrypted_dek: nil]],
        skip_tenant_check: true
      )

    assert {:error, _} = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
    assert reload(ctx.stale).payload_hash == nil
    assert Agent.get(ctx.store, & &1.overwrites) == []
  end

  # Once done, the migration re-checks daily on the existing runner cron, so
  # a row a lost race unstamped is healed without waiting for an edit.
  test "a done migration reopens for a row unstamped later", ctx do
    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
    assert NotePayloadStamps.run_pass() == :done
    Indexing.unstamp_payload_hash(reload(ctx.stale))

    # The runner re-runs a done migration's pass daily only if it opts in.
    assert NotePayloadStamps.reverify?()
    assert {:more, users: 1} = NotePayloadStamps.run_pass()
    assert_enqueued(worker: ReconcileNotePayloads, args: %{"user_id" => ctx.user.id})
  end

  test "a rotation that starts mid-job snoozes it before any write", ctx do
    uid = ctx.user.id

    Agent.update(ctx.store, fn s ->
      %{
        s
        | on_scroll: fn ->
            Repo.update_all(
              from(u in Engram.Accounts.User, where: u.id == ^uid),
              [set: [dek_rotation_locked_at: DateTime.utc_now()]],
              skip_tenant_check: true
            )
          end
      }
    end)

    assert {:snooze, _} = perform_job(ReconcileNotePayloads, %{"user_id" => uid})
    assert Agent.get(ctx.store, & &1.set_payloads) == []
    assert reload(ctx.healthy).payload_hash == nil
  end

  test "Qdrant refusing writes (507) snoozes the job instead of burning an attempt", ctx do
    Agent.update(ctx.store, &%{&1 | payload_status: 507})
    assert {:snooze, _} = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
    assert reload(ctx.stale).payload_hash == nil
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

  # #2138: prod has no `u` index until the v5 format is on, and Qdrant
  # Cloud's strict mode (`unindexed_filtering_retrieve: false`) answers 400
  # to any filter on an unindexed key. The fake refuses the same way, so a
  # read filter naming `u` while v5 is off fails every test above; this one
  # pins prod's exact state (legacy points, v5 off).
  test "the payload read filters only on indexed keys while v5 is off", ctx do
    refute Engram.Vector.Qdrant.v5_payload_format?()
    assert :ok = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
    assert reload(ctx.stale).payload_hash
    assert reload(ctx.healthy).payload_hash
  end

  # A request Qdrant will refuse on every retry is cancelled once, with its
  # status logged, instead of five redacted `:error` attempts.
  # A cancel is retried by the hourly re-check, so a refusal that never clears
  # would cancel once an hour forever. The counter is what an alert sees.
  test "a permanent scroll refusal cancels the job and logs its status", ctx do
    Agent.update(ctx.store, &%{&1 | scroll_status: 400})
    event = [:engram, :indexing, :payload_reconcile_cancelled]
    ref = :telemetry_test.attach_event_handlers(self(), [event])

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:cancel, {:qdrant_scroll, 400, _}} =
                 perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
      end)

    assert log =~ "note payload reconcile failed"
    assert log =~ ":qdrant_scroll 400"
    refute log =~ ctx.stale.id
    assert reload(ctx.stale).payload_hash == nil
    assert_receive {^event, ^ref, %{count: 1}, %{http_status: 400}}
  end

  test "a transient scroll error (503) snoozes, a 500 fails for a backoff", ctx do
    Agent.update(ctx.store, &%{&1 | scroll_status: 503})
    assert {:snooze, _} = perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})

    Agent.update(ctx.store, &%{&1 | scroll_status: 500})

    assert {:error, {:qdrant_scroll, 500, _}} =
             perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
  end

  test "a permanent payload-write refusal cancels the job", ctx do
    Agent.update(ctx.store, &%{&1 | payload_status: 422})

    assert {:cancel, {422, _}} =
             perform_job(ReconcileNotePayloads, %{"user_id" => ctx.user.id})
  end

  # The v5 format on, as prod runs it after the rebuild: `u` is indexed.
  defp v5_on(ctx) do
    Engram.ServiceConfig.put_override(:write_v5_layout, true)
    Agent.update(ctx.store, &%{&1 | v5_indexes: true})
  end

  # The v3 cluster: v5 on and LEGACY_FILTER_FIELDS=false, so the fake has
  # no legacy index and refuses any filter on a legacy key, as v3 would.
  defp v3_on(ctx) do
    v5_on(ctx)
    Engram.ServiceConfig.put_override(:legacy_filter_fields, false)
    Agent.update(ctx.store, &%{&1 | legacy_indexes: false})
  end

  # A v5 point a rotation left on the retired key. `u` is the tenant id, not
  # an HMAC, so a rotation never changes it.
  defp retired_v5(ctx), do: %{"u" => FilterId.uuid(ctx.user.id), "y" => "b2xk"}

  defp reload(note),
    do: Repo.one!(from(n in Note, where: n.id == ^note.id), skip_tenant_check: true)

  defp point_ids(note) do
    Repo.all(from(c in Chunk, where: c.note_id == ^note.id, select: c.qdrant_point_id),
      skip_tenant_check: true
    )
  end

  defp fake_qdrant(conn, store) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
    body = if body == "", do: %{}, else: Jason.decode!(body)
    status = Agent.get(store, & &1.payload_status)
    scroll_status = Agent.get(store, & &1.scroll_status)
    scroll? = String.ends_with?(conn.request_path, "/points/scroll")

    cond do
      status != 200 and String.ends_with?(conn.request_path, "/points/payload") ->
        Plug.Conn.send_resp(conn, status, "{}")

      scroll? and scroll_status != nil ->
        Plug.Conn.send_resp(conn, scroll_status, "{}")

      scroll? and
          unindexed(body["filter"], Agent.get(store, &{&1.v5_indexes, &1.legacy_indexes})) !=
            [] ->
        # Qdrant Cloud strict mode, `unindexed_filtering_retrieve: false`.
        Plug.Conn.send_resp(conn, 400, ~s({"status":{"error":"Bad request: Index required"}}))

      true ->
        fake_reply(conn, store, body)
    end
  end

  defp unindexed(filter, {v5?, legacy?}) do
    indexed = for {key, _} <- QdrantLayout.payload_indexes(nil, v5?, legacy?), do: key
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

        {"PUT", "/collections/engram_notes/points/payload"} ->
          if hook = Agent.get(store, & &1.on_write), do: hook.()

          ids = for %{"has_id" => ids} <- body["filter"]["should"], id <- ids, do: id

          Agent.update(store, fn s ->
            points = Enum.reduce(ids, s.points, &Map.put(&2, &1, body["payload"]))
            %{s | points: points, overwrites: [ids | s.overwrites]}
          end)

          %{"status" => "completed"}

        {"POST", "/collections/engram_notes/points/scroll"} ->
          if hook = Agent.get(store, & &1.on_scroll), do: hook.()

          # The whole filter is evaluated, as Qdrant would: a heal whose
          # filter hides a point layout must not pass here by accident.
          filter = body["filter"]
          assert Enum.any?(filter["must"] || [], &Map.has_key?(&1, "has_id"))

          %{
            "points" =>
              for(
                {id, payload} <- Agent.get(store, & &1.points),
                filter?(id, payload, filter),
                do: %{"id" => id, "payload" => Map.take(payload, body["with_payload"])}
              ),
            "next_page_offset" => nil
          }

        _other ->
          true
      end

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => result, "status" => "ok"}))
  end
end
