defmodule Engram.Workers.SettleIndexEntriesTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{CrdtIndexDoc, CrdtIndexPersistence, Identity}
  alias Engram.Workers.SettleIndexEntries

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "Settle", Ecto.UUID.generate())

    {:ok, n} =
      Notes.upsert_note(user, vault, %{"path" => "Docs/n.md", "content" => "x"}, actor: "api")

    %{user: user, vault: vault, n: n}
  end

  defp jobs do
    Repo.all(from(j in Oban.Job, where: j.worker == "Engram.Workers.SettleIndexEntries"))
  end

  defp index_path(ctx, note_id) do
    {:ok, doc} = CrdtIndexPersistence.load_doc(ctx.user, ctx.vault.id)
    map = doc |> Yex.Doc.get_map(CrdtIndexDoc.map_name()) |> Yex.Map.to_map()
    Enum.find_value(map, fn {path, v} -> if v["note_id"] == note_id, do: path end)
  end

  # A failed op whose inline settle failed: the claim stands at the refused
  # path, the row did not move. The job brings the entry back to the row, and
  # running it again changes nothing.
  test "the retry settles the entry onto the committed row, idempotently", ctx do
    :ok = Identity.claim(ctx.user, ctx.vault.id, [{"Archive/n.md", ctx.n.id}])

    :ok =
      SettleIndexEntries.enqueue(ctx.user, ctx.vault.id, [{ctx.n.id, "Docs/n.md", "Archive/n.md"}])

    assert [job] = jobs()
    refute Enum.any?(Map.values(job.args), &(is_binary(&1) and &1 =~ "Docs/"))

    assert :ok = perform_job(SettleIndexEntries, job.args)
    assert index_path(ctx, ctx.n.id) == "Docs/n.md"
    assert :ok = perform_job(SettleIndexEntries, job.args)
    assert index_path(ctx, ctx.n.id) == "Docs/n.md"
  end

  # A second failure for a note whose retry is still pending must not be
  # dropped: its paths join the pending job, so the retry may move an entry
  # the second op claimed.
  test "a second failure while a retry is pending merges into that job", ctx do
    :ok = SettleIndexEntries.enqueue(ctx.user, ctx.vault.id, [{ctx.n.id, "Docs/n.md", "A/n.md"}])
    :ok = Identity.claim(ctx.user, ctx.vault.id, [{"B/n.md", ctx.n.id}])
    :ok = SettleIndexEntries.enqueue(ctx.user, ctx.vault.id, [{ctx.n.id, "Docs/n.md", "B/n.md"}])

    assert [job] = jobs()
    assert length(job.args["allowed"]) == 4

    assert :ok = perform_job(SettleIndexEntries, job.args)
    assert index_path(ctx, ctx.n.id) == "Docs/n.md"
  end
end
