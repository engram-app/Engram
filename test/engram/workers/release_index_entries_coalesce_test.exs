defmodule Engram.Workers.ReleaseIndexEntriesCoalesceTest do
  @moduledoc """
  Releases coalesce per vault (2026-10-24 speed audit).

  Every release job rewrites the whole `filemeta_v0` index once per chunk, so
  its cost is a fixed part that scales with the index. Deleting K notes one
  request at a time used to queue K jobs: K full rewrites, O(K x index). A
  release now joins the vault's job that is still waiting to run, so a burst
  of deletes costs one rewrite per chunk.
  """
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Workers.ReleaseIndexEntries

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "Coalesce", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp note(ctx, vault \\ nil, path) do
    {:ok, note} =
      Notes.upsert_note(ctx.user, vault || ctx.vault, %{"path" => path, "content" => "x"},
        actor: "api"
      )

    note
  end

  defp release_jobs do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == "Engram.Workers.ReleaseIndexEntries",
        order_by: j.id
      )
    )
  end

  test "deleting many notes one request at a time queues ONE release job with every id", ctx do
    notes = for i <- 1..25, do: note(ctx, "n#{i}.md")

    for n <- notes, do: assert(:ok = Notes.delete_note(ctx.user, ctx.vault, n.path))

    assert [job] = release_jobs()
    assert job.args["vault_id"] == ctx.vault.id
    assert job.args["note_ids"] == Enum.map(notes, & &1.id)
  end

  test "the coalesced job releases every note it carries", ctx do
    notes = for i <- 1..3, do: note(ctx, "r#{i}.md")
    for n <- notes, do: :ok = Notes.delete_note(ctx.user, ctx.vault, n.path)

    assert [job] = release_jobs()
    assert :ok = perform_job(ReleaseIndexEntries, job.args)
  end

  test "a job already running is never extended: the next delete queues a fresh one", ctx do
    a = note(ctx, "a.md")
    b = note(ctx, "b.md")
    :ok = Notes.delete_note(ctx.user, ctx.vault, a.path)

    [running] = release_jobs()
    Repo.update_all(from(j in Oban.Job, where: j.id == ^running.id), set: [state: "executing"])

    :ok = Notes.delete_note(ctx.user, ctx.vault, b.path)

    assert [first, second] = release_jobs()
    assert first.args["note_ids"] == [a.id]
    assert second.args["note_ids"] == [b.id]
  end

  test "releases for different vaults stay in their own jobs", ctx do
    {:ok, other, _} = Vaults.register_vault(ctx.user, "Other", Ecto.UUID.generate())
    a = note(ctx, "a.md")
    b = note(ctx, other, "b.md")

    :ok = Notes.delete_note(ctx.user, ctx.vault, a.path)
    :ok = Notes.delete_note(ctx.user, other, b.path)

    by_vault = Map.new(release_jobs(), &{&1.args["vault_id"], &1.args["note_ids"]})
    assert by_vault == %{ctx.vault.id => [a.id], other.id => [b.id]}
  end

  test "a batch delete joins the vault's pending release too", ctx do
    a = note(ctx, "a.md")
    b = note(ctx, "b.md")
    c = note(ctx, "c.md")

    :ok = Notes.delete_note(ctx.user, ctx.vault, a.path)
    {:ok, _} = Notes.batch_delete_notes(ctx.user, ctx.vault, [b.id, c.id])

    assert [job] = release_jobs()
    assert Enum.sort(job.args["note_ids"]) == Enum.sort([a.id, b.id, c.id])
  end

  test "no ids queues nothing and touches no pending job", ctx do
    a = note(ctx, "a.md")
    :ok = Notes.delete_note(ctx.user, ctx.vault, a.path)

    assert {:ok, :skipped} = ReleaseIndexEntries.enqueue(ctx.user.id, ctx.vault.id, [])
    assert [job] = release_jobs()
    assert job.args["note_ids"] == [a.id]
  end

  defp ids(n), do: for(_ <- 1..n, do: Ecto.UUID.generate())

  # Review of #2209 (M3): a pending job, a chain successor included, kept
  # absorbing ids without bound. A job holds at most one chunk's worth of
  # joined ids; past that a release queues its own job.
  test "a pending job holding a full chunk is not extended", ctx do
    full = ids(ReleaseIndexEntries.chunk_size())
    {:ok, _} = ReleaseIndexEntries.enqueue(ctx.user.id, ctx.vault.id, full)
    [extra] = ids(1)
    {:ok, _} = ReleaseIndexEntries.enqueue(ctx.user.id, ctx.vault.id, [extra])

    assert [first, second] = release_jobs()
    assert first.args["note_ids"] == full
    assert second.args["note_ids"] == [extra]
  end

  test "a release that would overflow the pending job queues its own", ctx do
    almost = ids(ReleaseIndexEntries.chunk_size() - 1)
    two = ids(2)
    {:ok, _} = ReleaseIndexEntries.enqueue(ctx.user.id, ctx.vault.id, almost)
    {:ok, _} = ReleaseIndexEntries.enqueue(ctx.user.id, ctx.vault.id, two)

    assert Enum.map(release_jobs(), &length(&1.args["note_ids"])) ==
             [ReleaseIndexEntries.chunk_size() - 1, 2]
  end

  test "a release filling the pending job exactly joins it", ctx do
    almost = ids(ReleaseIndexEntries.chunk_size() - 1)
    [last] = ids(1)
    {:ok, _} = ReleaseIndexEntries.enqueue(ctx.user.id, ctx.vault.id, almost)
    {:ok, :joined} = ReleaseIndexEntries.enqueue(ctx.user.id, ctx.vault.id, [last])

    assert [job] = release_jobs()
    assert length(job.args["note_ids"]) == ReleaseIndexEntries.chunk_size()
  end

  # Review of #2209 (M2): the lookup runs on every note delete, usually to find
  # nothing. Without a queue predicate and with ORDER BY id it invited a walk
  # of oban_jobs by primary key. It must be an index probe on a state-leading
  # Oban index, filtered by queue. (On this near-empty table the planner picks
  # `oban_jobs_state_discarded_at_index`; a busy table can prefer the
  # `(state, queue, ...)` one. Either is a state probe, never a pkey walk.)
  test "the pending-job lookup is a state index probe filtered by queue", ctx do
    {_, queries} =
      Engram.QueryRecorder.record(fn ->
        ReleaseIndexEntries.enqueue(ctx.user.id, ctx.vault.id, ids(1))
      end)

    [sql] =
      for sql <- Engram.QueryPlan.reading(queries, "oban_jobs"), sql =~ "jsonb_set", do: sql

    refute sql =~ "ORDER BY", sql
    assert sql =~ ~s("queue" = ), sql
    plan = Engram.QueryPlan.generic_plan(sql, analyze: ["oban_jobs"], bitmapscan: false)

    assert plan =~ ~r/LockRows\s+.*\n\s+->\s+Index Scan using oban_jobs_state_\w+ on oban_jobs/,
           plan

    assert plan =~ ~r/Index Cond: \(state = /, plan
  end
end
