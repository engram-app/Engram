defmodule Engram.DataMigrations.FileTimesTest do
  @moduledoc """
  R25 backfill, v4 (contract step (a)): a NULL twin is filled from its
  double (a `0` as the epoch), a twin within 1 us of it is refined, a twin
  further off is kept (the double is the stale one beside a step (b)
  node), millisecond doubles normalized, and a rerun is a no-op.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import ExUnit.CaptureLog

  alias Engram.Attachments
  alias Engram.Attachments.Attachment
  alias Engram.Attachments.Upload
  alias Engram.Attachments.Uploads
  alias Engram.DataMigrations.FileTimes
  alias Engram.FileTime
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Workers.DataMigrationsRunner

  setup do
    FileTimes.forget()
    on_exit(&FileTimes.forget/0)
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp note!(ctx, path, times) do
    {:ok, n} =
      Notes.upsert_note(
        ctx.user,
        ctx.vault,
        Map.merge(%{"path" => path, "content" => "x\n"}, times),
        actor: "api"
      )

    n.id
  end

  # Writes behind the writers' back: what a previous release (or a bug)
  # leaves behind.
  defp set!(ctx, schema, id, fields) do
    Repo.with_tenant!(ctx.user.id, fn ->
      {1, _} = Repo.update_all(from(r in schema, where: r.id == ^id), set: fields)
    end)
  end

  defp rows(ctx, schema, pairs) do
    Repo.with_tenant!(ctx.user.id, fn ->
      keys = [:id | Enum.flat_map(pairs, &Tuple.to_list/1)]
      schema |> Repo.all() |> Enum.map(&Map.take(&1, keys))
    end)
  end

  defp assert_parity!(ctx, schema, pairs) do
    for row <- rows(ctx, schema, pairs), {double, at} <- pairs do
      assert FileTime.same_at?(row[at], FileTime.normalize(row[double])), inspect({schema, row})
    end
  end

  defp run_to_done(opts \\ [batch: 2]) do
    Stream.repeatedly(fn -> FileTimes.run_pass(opts) end)
    |> Enum.take_while(&(&1 != :done))
    |> Enum.take(50)
  end

  test "fills NULL twins, keeps far-off ones, normalizes ms, rerun is a no-op", ctx do
    ok = note!(ctx, "ok.md", %{"mtime" => 1_776_072_500.928, "ctime" => 1_510_897_528.861})
    null = note!(ctx, "null.md", %{"mtime" => 1_776_072_500.9, "ctime" => 1_510_897_528.0})
    drift = note!(ctx, "drift.md", %{"mtime" => 1_776_072_600.5})
    ms = note!(ctx, "ms.md", %{"mtime" => 1.0})
    big = note!(ctx, "big.md", %{"mtime" => 1.0})
    after_big = note!(ctx, "z.md", %{"mtime" => 1_700_000_000.25})

    # Pre-expand rows: double, no twin.
    set!(ctx, Note, null, mtime_at: nil, ctime_at: nil)
    set!(ctx, Note, after_big, mtime_at: nil)
    # The double moved without its twin (a step (b) node leaves the double
    # stale): the twin is the authority and is kept.
    set!(ctx, Note, drift, mtime: 1_776_090_000.75)
    set!(ctx, Note, ms, mtime: 1_776_072_500_928.0, mtime_at: nil)
    # A legacy out-of-range double: its twin is kept too.
    set!(ctx, Note, big, mtime: 1.0e19, mtime_at: ~U[2020-01-01 00:00:00.000000Z])

    capture_log(fn -> assert [{:more, rows: 3} | _] = run_to_done() end)

    by_id = Map.new(rows(ctx, Note, mtime: :mtime_at, ctime: :ctime_at), &{&1.id, &1})
    assert by_id[ms].mtime_at == ~U[2026-04-13 09:28:20.928000Z]
    assert by_id[drift].mtime_at == FileTime.to_at!(1_776_072_600.5)
    assert by_id[big].mtime_at == ~U[2020-01-01 00:00:00.000000Z]
    assert by_id[ok].mtime_at == ~U[2026-04-13 09:28:20.928000Z]
    assert by_id[null].mtime_at == FileTime.to_at!(1_776_072_500.9)
    assert by_id[null].ctime_at == FileTime.to_at!(1_510_897_528.0)
    assert by_id[after_big].mtime_at == FileTime.to_at!(1_700_000_000.25)

    # Rerun: one clean walk, nothing written.
    before = rows(ctx, Note, mtime: :mtime_at, ctime: :ctime_at)
    assert FileTimes.run_pass(batch: 2) == :done
    assert rows(ctx, Note, mtime: :mtime_at, ctime: :ctime_at) == before
  end

  test "attachments and upload sessions are backfilled too", ctx do
    {:ok, att} =
      Attachments.upsert_attachment(ctx.user, ctx.vault, %{
        "path" => "a.png",
        :content => "png",
        "mtime" => 1_776_072_500.928
      })

    {:ok, %Upload{} = up} =
      Uploads.start(ctx.user, ctx.vault, %{path: "d.bin", size_bytes: 3, mtime: 1_776_072_500.5})

    set!(ctx, Attachment, att.id, mtime: 1_776_072_500_928.0, mtime_at: nil)
    set!(ctx, Upload, up.id, mtime_at: nil)

    capture_log(fn -> run_to_done() end)

    assert_parity!(ctx, Attachment, mtime: :mtime_at)
    assert_parity!(ctx, Upload, mtime: :mtime_at)
    assert FileTimes.run_pass(batch: 2) == :done
  end

  test "is registered with the runner" do
    assert FileTimes in DataMigrationsRunner.migrations()
  end

  # Contract step (a): 0.87 stored a `0` with a NULL twin, which would read
  # back as nil once the doubles go. v4 fills the epoch, which reads as 0.
  test "a 0 double with a NULL twin gets the epoch twin", ctx do
    id = note!(ctx, "zero.md", %{"mtime" => 1.0})
    set!(ctx, Note, id, mtime: 0.0, mtime_at: nil)

    {:ok, att} =
      Attachments.upsert_attachment(ctx.user, ctx.vault, %{
        "path" => "z.png",
        :content => "png",
        "mtime" => 1.0
      })

    set!(ctx, Attachment, att.id, mtime: 0.0, mtime_at: nil)

    capture_log(fn -> run_to_done() end)

    assert [%{mtime_at: ~U[1970-01-01 00:00:00.000000Z]}] = rows(ctx, Note, mtime: :mtime_at)

    assert [%{mtime_at: ~U[1970-01-01 00:00:00.000000Z]}] =
             rows(ctx, Attachment, mtime: :mtime_at)
  end

  # Review of #2625: a step (b) node moves the twin alone (its double stays
  # stale). A window that read the row before that write must not land.
  test "the write guards on the twin it read, not only the double", ctx do
    id = note!(ctx, "race.md", %{"mtime" => 1_700_000_000.5})
    set!(ctx, Note, id, mtime_at: nil)

    [read] =
      Repo.with_tenant!(ctx.user.id, fn ->
        Repo.all(from(n in Note, select: map(n, [:id, :mtime, :mtime_at, :ctime, :ctime_at])))
      end)

    # The (b) write: a new twin, the double left as it was.
    set!(ctx, Note, id, mtime_at: ~U[2030-01-01 00:00:00.000000Z])

    wanted = %{mtime_at: FileTime.normalize(read.mtime), ctime_at: read.ctime_at}

    assert Repo.with_tenant!(ctx.user.id, fn -> FileTimes.write(Repo, Note, [{read, wanted}]) end) ==
             []

    assert [%{mtime_at: ~U[2030-01-01 00:00:00.000000Z]}] = rows(ctx, Note, mtime: :mtime_at)
  end

  test "wanted/2: fill a NULL twin, refine within 1 us, else keep the twin" do
    t = 2_147_484_020.404
    want = FileTime.normalize(t)
    low = DateTime.add(want, -1, :microsecond)
    far = ~U[2030-01-01 00:00:00.000000Z]

    assert FileTimes.wanted(nil, t) == want
    assert FileTimes.wanted(low, t) == want
    assert FileTimes.wanted(far, t) == far
    assert FileTimes.wanted(far, nil) == far
    assert FileTimes.wanted(nil, nil) == nil
    assert FileTimes.wanted(nil, 0.0) == ~U[1970-01-01 00:00:00.000000Z]
  end

  test "a clean table is skipped while another is open, then confirmed before done", ctx do
    {:ok, att} =
      Attachments.upsert_attachment(ctx.user, ctx.vault, %{
        "path" => "a.png",
        :content => "png",
        "mtime" => 1_776_072_500.5
      })

    for p <- ~w(a b c),
        do: set!(ctx, Note, note!(ctx, "#{p}.md", %{"mtime" => 7.0}), mtime_at: nil)

    # One note per pass keeps notes open; attachments and uploads walk clean.
    assert {:more, _} = FileTimes.run_pass(batch: 1, max_fixed: 1)

    # Drift written after attachments walked clean is skipped while notes
    # stay open...
    set!(ctx, Attachment, att.id, mtime_at: nil)
    assert {:more, _} = FileTimes.run_pass(batch: 1, max_fixed: 1)
    assert [%{mtime_at: nil}] = rows(ctx, Attachment, mtime: :mtime_at)

    # ...but the ledger closes only after one confirming pass over all
    # three tables, so it is repaired before `:done`.
    run_to_done(batch: 1, max_fixed: 1)
    assert_parity!(ctx, Attachment, mtime: :mtime_at)
    assert_parity!(ctx, Note, mtime: :mtime_at, ctime: :ctime_at)
  end

  test "the runner sets completed_at only after drift behind a clean walk is repaired", ctx do
    {:ok, att} =
      Attachments.upsert_attachment(ctx.user, ctx.vault, %{
        "path" => "a.png",
        :content => "png",
        "mtime" => 1_776_072_500.5
      })

    set!(ctx, Note, note!(ctx, "a.md", %{"mtime" => 7.0}), mtime_at: nil)
    set!(ctx, Note, note!(ctx, "b.md", %{"mtime" => 8.0}), mtime_at: nil)

    # Attachments walk clean now; notes stay open (one row per walk).
    assert {:more, _} = FileTimes.run_pass(batch: 1, max_fixed: 1)
    set!(ctx, Attachment, att.id, mtime_at: nil)

    Stream.repeatedly(fn -> DataMigrationsRunner.run(FileTimes) end)
    |> Stream.take(20)
    |> Enum.find(&(&1 in [:done, :skipped]))

    assert Engram.DataMigrations.done?(FileTimes.name(), FileTimes.version())
    assert_parity!(ctx, Attachment, mtime: :mtime_at)
  end

  # R3a: no point carries a date, so a fixed twin rewrites no payload and
  # leaves every stamp alone.
  test "a fixed millisecond note keeps its payload stamp; no heal is queued", ctx do
    ms = note!(ctx, "ms.md", %{"mtime" => 1.0})
    s = note!(ctx, "s.md", %{"mtime" => 1.0})
    set!(ctx, Note, ms, mtime: 1_776_072_500_928.0, mtime_at: nil, payload_hash: <<1::256>>)
    set!(ctx, Note, s, mtime: 1_776_072_500.5, mtime_at: nil, payload_hash: <<2::256>>)

    run_to_done()

    hashes =
      Repo.with_tenant!(ctx.user.id, fn ->
        Map.new(Repo.all(from(n in Note, select: {n.id, n.payload_hash})))
      end)

    assert hashes[ms] == <<1::256>>
    assert hashes[s] == <<2::256>>
    refute_enqueued(worker: Engram.Workers.ReconcileNotePayloads)
  end

  # v2: 0.74 and 0.75 floored the twin to the microsecond, about a quarter
  # of 2004-2005 and post-2038 millisecond values 1 us low. Readers already
  # sent the double for those (`FileTime.twin?/2`), so no payload refresh.
  test "v2 rewrites a floored v1 twin to the rounded value, no payload refresh", ctx do
    t = 2_147_484_020.404
    ms = 1_104_537_600_123.0
    s_id = note!(ctx, "s.md", %{"mtime" => t})
    ms_id = note!(ctx, "ms.md", %{"mtime" => 1.0})
    low = &DateTime.add(FileTime.normalize(&1), -1, :microsecond)
    set!(ctx, Note, s_id, mtime_at: low.(t), payload_hash: <<1::256>>)
    set!(ctx, Note, ms_id, mtime: ms, mtime_at: low.(ms), payload_hash: <<2::256>>)

    capture_log(fn -> run_to_done() end)

    by_id = Map.new(rows(ctx, Note, mtime: :mtime_at), &{&1.id, &1})
    assert by_id[s_id].mtime_at == ~U[2038-01-19 03:20:20.404000Z]
    assert by_id[ms_id].mtime_at == ~U[2005-01-01 00:00:00.123000Z]

    hashes =
      Repo.with_tenant!(ctx.user.id, fn ->
        Map.new(Repo.all(from(n in Note, select: {n.id, n.payload_hash})))
      end)

    assert {hashes[s_id], hashes[ms_id]} == {<<1::256>>, <<2::256>>}
    refute_enqueued(worker: Engram.Workers.ReconcileNotePayloads)
  end

  test "kill switch: with file_times_backfill off the runner runs no pass", ctx do
    id = note!(ctx, "a.md", %{"mtime" => 7.0})
    set!(ctx, Note, id, mtime_at: nil)
    Engram.ServiceConfig.put_override(:file_times_backfill, false)

    refute FileTimes.enabled?()
    assert DataMigrationsRunner.run(FileTimes) == :skipped
    assert [%{mtime_at: nil}] = rows(ctx, Note, mtime: :mtime_at)
    refute Engram.DataMigrations.done?(FileTimes.name(), FileTimes.version())
  end

  # A 0.75-or-older node floors every twin it writes: the ledger must not
  # close while one runs, and the walk that closes it must start after.
  test "the ledger stays open while an old-build node is reported", ctx do
    t = 2_147_484_020.404
    id = note!(ctx, "s.md", %{"mtime" => t})
    floored = DateTime.add(FileTime.normalize(t), -1, :microsecond)
    set!(ctx, Note, id, mtime_at: floored)

    old = [
      peers: fn -> [:"engram@10.0.0.9"] end,
      sync: fn -> :ok end,
      multicall: fn _ -> [{:error, {:exception, :undef, []}}] end
    ]

    for _ <- 1..3, do: assert(FileTimes.run_pass(batch: 2, fleet: old) == {:more, rows: 0})
    assert [%{mtime_at: ^floored}] = rows(ctx, Note, mtime: :mtime_at)

    # A v2 node (rounds the float product) holds it open too.
    v2 = Keyword.put(old, :multicall, fn _ -> [{:ok, 1}] end)
    assert FileTimes.run_pass(batch: 2, fleet: v2) == {:more, rows: 0}
    assert [%{mtime_at: ^floored}] = rows(ctx, Note, mtime: :mtime_at)

    # A 0.87 node (rounding 2) stores a `0` as NULL: it holds it open too.
    v87 = Keyword.put(old, :multicall, fn _ -> [{:ok, 2}] end)
    assert FileTimes.run_pass(batch: 2, fleet: v87) == {:more, rows: 0}
    assert [%{mtime_at: ^floored}] = rows(ctx, Note, mtime: :mtime_at)

    new = Keyword.put(old, :multicall, fn _ -> [{:ok, 3}] end)
    capture_log(fn -> run_to_done(batch: 2, fleet: new) end)
    assert [%{mtime_at: ~U[2038-01-19 03:20:20.404000Z]}] = rows(ctx, Note, mtime: :mtime_at)
    assert FileTimes.run_pass(batch: 2, fleet: new) == :done
  end

  # Acceptance: all four columns, compared to the ROUNDED twin in Elixir;
  # `count_drift/1` is the read-only prod verification (`bin/engram rpc`).
  test "count_drift/1 counts each column's drifted twins; zero after the walk", ctx do
    t = 2_147_484_020.404
    low = DateTime.add(FileTime.normalize(t), -1, :microsecond)
    id = note!(ctx, "n.md", %{"mtime" => t, "ctime" => t})
    set!(ctx, Note, id, mtime_at: low, ctime_at: nil)

    {:ok, att} =
      Attachments.upsert_attachment(ctx.user, ctx.vault, %{
        "path" => "a.png",
        :content => "png",
        "mtime" => t
      })

    {:ok, up} = Uploads.start(ctx.user, ctx.vault, %{path: "d.bin", size_bytes: 3, mtime: t})
    set!(ctx, Attachment, att.id, mtime_at: low)
    set!(ctx, Upload, up.id, mtime_at: low)

    before = rows(ctx, Note, mtime: :mtime_at, ctime: :ctime_at)

    assert FileTimes.count_drift(batch_size: 1) == %{
             "notes.mtime" => 1,
             "notes.ctime" => 1,
             "attachments.mtime" => 1,
             "attachment_uploads.mtime" => 1
           }

    assert rows(ctx, Note, mtime: :mtime_at, ctime: :ctime_at) == before

    capture_log(fn -> run_to_done() end)

    assert FileTimes.count_drift() |> Map.values() |> Enum.uniq() == [0]
  end

  # A 0.75 node that joins after close floors twins again; the daily
  # re-walk (`reverify?/0`) finds them and reopens the ledger.
  test "a done ledger reopens when the re-verify walk finds drift", ctx do
    t = 2_147_484_020.404
    id = note!(ctx, "s.md", %{"mtime" => t})

    Stream.repeatedly(fn -> DataMigrationsRunner.run(FileTimes) end)
    |> Stream.take(20)
    |> Enum.find(&(&1 in [:done, :skipped]))

    assert Engram.DataMigrations.done?(FileTimes.name(), FileTimes.version())
    assert FileTimes.reverify?()

    set!(ctx, Note, id, mtime_at: DateTime.add(FileTime.normalize(t), -1, :microsecond))

    capture_log(fn -> assert DataMigrationsRunner.run(FileTimes, true) == :more end)
    refute Engram.DataMigrations.done?(FileTimes.name(), FileTimes.version())
    assert [%{mtime_at: ~U[2038-01-19 03:20:20.404000Z]}] = rows(ctx, Note, mtime: :mtime_at)
  end

  test "the fleet gate never calls :global.sync/0 (it stalls on a partition)" do
    assert FileTimes.fleet_opts([])[:sync].() == :ok
    own = fn -> :called end
    assert FileTimes.fleet_opts(fleet: [sync: own])[:sync] == own
  end

  # v3: v2 rounded the float product, so 1792348622.2113965 (exactly
  # ...2113964557...) was stored ...211397; the exact rounding is ...211396.
  test "v3 rewrites a v2 float-product twin to the exact rounding", ctx do
    t5 = 1_792_348_622.2113965
    id = note!(ctx, "t5.md", %{"mtime" => t5})
    set!(ctx, Note, id, mtime_at: ~U[2026-10-18 18:37:02.211397Z], payload_hash: <<1::256>>)
    assert FileTime.twin?(~U[2026-10-18 18:37:02.211397Z], t5)

    capture_log(fn -> run_to_done() end)

    assert [%{mtime_at: ~U[2026-10-18 18:37:02.211396Z]}] = rows(ctx, Note, mtime: :mtime_at)
    refute_enqueued(worker: Engram.Workers.ReconcileNotePayloads)
  end
end
