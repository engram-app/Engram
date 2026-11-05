defmodule Engram.DataMigrations.FileTimesTest do
  @moduledoc """
  R25 migrate-data backfill: every row whose `*_at` IS DISTINCT FROM
  `FileTime.to_at(double)` is recomputed (NULL and non-NULL drift alike, a
  previous release moves the double without its twin), millisecond doubles
  normalized, out-of-range legacy doubles counted and set NULL without
  stopping the walk, and a rerun is a no-op.
  """
  use Engram.DataCase, async: false

  import ExUnit.CaptureLog

  alias Engram.Attachments
  alias Engram.Attachments.Attachment
  alias Engram.Attachments.Upload
  alias Engram.Attachments.Uploads
  alias Engram.DataMigrations.FileTimes
  alias Engram.FileTime
  alias Engram.Notes
  alias Engram.Notes.Note

  setup do
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
      want =
        case FileTime.to_at(row[double]) do
          {:ok, want} -> want
          {:error, :out_of_range} -> nil
        end

      assert row[at] == want, inspect({schema, row})
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
    assert FileTimes in Engram.Workers.DataMigrationsRunner.migrations()
  end
end
