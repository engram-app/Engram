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
end
