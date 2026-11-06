defmodule Engram.DataMigrations.FileTimesTest do
  @moduledoc """
  R25 migrate-data backfill: every row whose `*_at` IS DISTINCT FROM
  `FileTime.to_at(double)` is recomputed (NULL and non-NULL drift alike, a
  previous release moves the double without its twin), millisecond doubles
  normalized, out-of-range legacy doubles counted and set NULL without
  stopping the walk, and a rerun is a no-op.
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

  test "repairs NULL and non-NULL drift, normalizes ms, counts out of range, rerun is a no-op",
       ctx do
    ok = note!(ctx, "ok.md", %{"mtime" => 1_776_072_500.928, "ctime" => 1_510_897_528.861})
    null = note!(ctx, "null.md", %{"mtime" => 1_776_072_500.9, "ctime" => 1_510_897_528.0})
    drift = note!(ctx, "drift.md", %{"mtime" => 1_776_072_600.5})
    ms = note!(ctx, "ms.md", %{"mtime" => 1.0})
    big = note!(ctx, "big.md", %{"mtime" => 1.0})
    after_big = note!(ctx, "z.md", %{"mtime" => 1_700_000_000.25})

    # Pre-expand rows: double, no twin.
    set!(ctx, Note, null, mtime_at: nil, ctime_at: nil)
    set!(ctx, Note, after_big, mtime_at: nil)
    # A previous release moved the double; the twin is stale but NOT NULL.
    set!(ctx, Note, drift, mtime: 1_776_090_000.75)
    set!(ctx, Note, ms, mtime: 1_776_072_500_928.0, mtime_at: nil)
    # A legacy out-of-range double with a (wrong) twin: NULL is right.
    set!(ctx, Note, big, mtime: 1.0e19, mtime_at: ~U[2020-01-01 00:00:00.000000Z])

    log = capture_log(fn -> assert [{:more, rows: 5} | _] = run_to_done() end)

    assert_parity!(ctx, Note, mtime: :mtime_at, ctime: :ctime_at)
    assert log =~ "file_time_out_of_range"

    by_id = Map.new(rows(ctx, Note, mtime: :mtime_at), &{&1.id, &1})
    assert by_id[ms].mtime_at == ~U[2026-04-13 09:28:20.928000Z]
    assert by_id[drift].mtime_at == FileTime.to_at!(1_776_090_000.75)
    assert by_id[big].mtime_at == nil
    assert by_id[ok].mtime_at == ~U[2026-04-13 09:28:20.928000Z]

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

    set!(ctx, Attachment, att.id, mtime: 1_776_072_500_928.0, mtime_at: ~U[2000-01-01 00:00:00Z])
    set!(ctx, Upload, up.id, mtime_at: nil)

    capture_log(fn -> run_to_done() end)

    assert_parity!(ctx, Attachment, mtime: :mtime_at)
    assert_parity!(ctx, Upload, mtime: :mtime_at)
    assert FileTimes.run_pass(batch: 2) == :done
  end

  test "is registered with the runner" do
    assert FileTimes in DataMigrationsRunner.migrations()
  end

  defp oor_lines(log),
    do: log |> String.split("\n") |> Enum.filter(&(&1 =~ "file_time_out_of_range"))

  test "out of range is logged once per pass per table, with the count", ctx do
    for p <- ~w(a b c d) do
      id = note!(ctx, "#{p}.md", %{"mtime" => 1.0})
      set!(ctx, Note, id, mtime: 1.0e19, mtime_at: ~U[2020-01-01 00:00:00.000000Z])
    end

    log = capture_log(fn -> FileTimes.run_pass(batch: 1) end)
    assert [line] = oor_lines(log)
    assert line =~ "total_count=4"
    assert line =~ "table=notes"

    # Written once: a later walk finds them clean and says nothing.
    log = capture_log(fn -> run_to_done(batch: 1) end)
    assert oor_lines(log) == []
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

  test "a fixed millisecond note gets its payload refreshed; no other note is touched", ctx do
    ms = note!(ctx, "ms.md", %{"mtime" => 1.0})
    s = note!(ctx, "s.md", %{"mtime" => 1.0})
    set!(ctx, Note, ms, mtime: 1_776_072_500_928.0, mtime_at: nil, payload_hash: <<1::256>>)
    set!(ctx, Note, s, mtime: 1_776_072_500.5, mtime_at: nil, payload_hash: <<2::256>>)

    run_to_done()

    hashes =
      Repo.with_tenant!(ctx.user.id, fn ->
        Map.new(Repo.all(from(n in Note, select: {n.id, n.payload_hash})))
      end)

    assert hashes[ms] == nil
    assert hashes[s] == <<2::256>>

    assert_enqueued(
      worker: Engram.Workers.ReconcileNotePayloads,
      args: %{"user_id" => ctx.user.id}
    )
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

    new = Keyword.put(old, :multicall, fn _ -> [{:ok, 1}] end)
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
end
