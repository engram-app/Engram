defmodule Engram.Workers.RewriteNoteLinksFolderTest do
  # A folder rename queues ONE link-rewrite chain grouped by linking note, not
  # one chain per moved note (#2523 S5). Before this, a note path-linking N
  # moved notes was rewritten N times: on staging a 1k-note move gave one index
  # note 1,000 version bumps in 8 min and 1.13 GB of WAL.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Notes
  alias Engram.Notes.CrdtUpdateLog
  alias Engram.ServiceConfig
  alias Engram.Workers.{ExtractNoteLinks, RewriteNoteLinks}

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  # Bulk insert (`insert_notes!/3`): 1,000 upserts run past the sandbox's
  # 120 s ownership timeout. Returns `%{id: id}` maps, in path order.
  defp seed_folder!(user, vault, folder, n) do
    user
    |> Engram.Fixtures.insert_notes!(
      vault,
      for(i <- 1..n, do: %{path: "#{folder}/n#{i}.md", content: "#{i}"})
    )
    |> Enum.map(&%{id: &1})
  end

  defp seed_source!(user, vault, path, content) do
    {:ok, source} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    :ok = Links.replace_links(user, vault, source.id, Parser.extract(content))
    source
  end

  defp authoritative!(user, note_id) do
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Engram.Fixtures.raw_note(note_id) end)
    {:ok, text} = Notes.authoritative_content(user, raw)
    text
  end

  # Every write a rewrite makes to a note: a CRDT tail append, or (legacy row)
  # a version bump through upsert_note.
  defp writes(user, note) do
    {:ok, {log, version}} =
      Repo.with_tenant(user.id, fn ->
        {Repo.aggregate(from(l in CrdtUpdateLog, where: l.note_id == ^note.id), :count),
         Repo.one(from(n in Engram.Notes.Note, where: n.id == ^note.id, select: n.version))}
      end)

    log + version
  end

  defp drain! do
    case all_enqueued(worker: RewriteNoteLinks) do
      [] ->
        :ok

      jobs ->
        Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.RewriteNoteLinks"))
        for %{args: args} <- jobs, do: assert(:ok = perform_job(RewriteNoteLinks, args))
        drain!()
    end
  end

  defp links(prefix, n), do: Enum.map_join(1..n, " ", &"[[#{prefix}/n#{&1}]]")

  defp folder_move_rewrites_once(user, vault, n) do
    moved = seed_folder!(user, vault, "docs", n)
    index = seed_source!(user, vault, "Index.md", links("docs", n))
    before = writes(user, index)

    {:ok, %{notes: ^n}} = Engram.Folders.rename(user, vault, "docs", "archive")

    # One chain, on its own queue, not one per moved note.
    assert [job] = all_enqueued(worker: RewriteNoteLinks)
    assert job.queue == "link_rewrite"
    assert length(job.args["targets"]) == n
    refute inspect(job.args) =~ "docs/"

    drain!()

    assert authoritative!(user, index.id) == links("archive", n)
    assert writes(user, index) - before == 1, "index note must be written exactly once"

    ids = MapSet.new(moved, & &1.id)
    resolved = for l <- Links.links_for_note(user, index.id), do: l.target_note_id
    assert length(resolved) == n
    assert Enum.all?(resolved, &MapSet.member?(ids, &1))
  end

  test "a 50-note folder move rewrites the index note once, in one chain", ctx do
    folder_move_rewrites_once(ctx.user, ctx.vault, 50)
  end

  test "every link form follows; bare links and other notes' links are untouched", ctx do
    %{user: user, vault: vault} = ctx
    seed_folder!(user, vault, "docs", 3)

    text =
      "q [[docs/n1]] alias [[docs/n1|One]] anchor [[docs/n2#H|Two]] embed ![[docs/n3.md]] " <>
        "md [x](docs/n2.md) bare [[n1]] other [[elsewhere/n1]]"

    refs = seed_source!(user, vault, "Refs.md", text)
    bare = seed_source!(user, vault, "Bare.md", "only [[n1]] and [[n2]]")
    bare_before = writes(user, bare)

    # A linking note inside the moved folder moves in the same cascade.
    inside = seed_source!(user, vault, "docs/inside.md", "sib [[docs/n1]] [[docs/n2]]")

    {:ok, _} = Engram.Folders.rename(user, vault, "docs", "archive")
    assert [_one_chain] = all_enqueued(worker: RewriteNoteLinks)
    drain!()

    assert authoritative!(user, refs.id) ==
             "q [[archive/n1]] alias [[archive/n1|One]] anchor [[archive/n2#H|Two]] " <>
               "embed ![[archive/n3.md]] md [x](archive/n2.md) bare [[n1]] other [[elsewhere/n1]]"

    assert authoritative!(user, bare.id) == "only [[n1]] and [[n2]]"
    assert writes(user, bare) == bare_before
    assert authoritative!(user, inside.id) == "sib [[archive/n1]] [[archive/n2]]"
  end

  test "kill switch off: the job snoozes and rewrites nothing; on again, it lands", ctx do
    %{user: user, vault: vault} = ctx
    seed_folder!(user, vault, "docs", 2)
    index = seed_source!(user, vault, "Index.md", links("docs", 2))
    {:ok, _} = Engram.Folders.rename(user, vault, "docs", "archive")
    [job] = all_enqueued(worker: RewriteNoteLinks)

    ServiceConfig.put_override(:link_rewrite, false)
    refute RewriteNoteLinks.enabled?()
    assert {:snooze, _} = perform_job(RewriteNoteLinks, job.args)
    assert authoritative!(user, index.id) == links("docs", 2)

    ServiceConfig.put_override(:link_rewrite, true)
    assert :ok = perform_job(RewriteNoteLinks, job.args)
    assert authoritative!(user, index.id) == links("archive", 2)
  end

  test "pages by linking note: a small batch walks every linker through successors", ctx do
    %{user: user, vault: vault} = ctx
    seed_folder!(user, vault, "docs", 3)
    sources = for i <- 1..5, do: seed_source!(user, vault, "S#{i}.md", links("docs", 3))
    {:ok, _} = Engram.Folders.rename(user, vault, "docs", "archive")
    [job] = all_enqueued(worker: RewriteNoteLinks)
    Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.RewriteNoteLinks"))

    {:ok, _} = job.args |> Map.put("batch_size", 2) |> RewriteNoteLinks.new() |> Oban.insert()
    result = Oban.drain_queue(queue: :link_rewrite, with_recursion: true)
    assert result.failure == 0

    # 5 linkers at 2 a page: 3 pages, then the delayed sweep (scheduled).
    assert result.success == 3
    for s <- sources, do: assert(authoritative!(user, s.id) == links("archive", 3))
  end

  test "old per-note args queued on :indexing by an old node still perform", ctx do
    %{user: user, vault: vault} = ctx

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "#"}, actor: "api")

    {:ok, renamed} = Notes.rename_note(user, vault, "Old.md", "Fresh.md")
    [new_job] = all_enqueued(worker: RewriteNoteLinks)
    assert new_job.queue == "link_rewrite"
    Repo.delete_all(from(j in Oban.Job, where: j.worker == "Engram.Workers.RewriteNoteLinks"))
    src = seed_source!(user, vault, "S.md", "see [[Old]]")

    # Exactly the row an old node inserts: per-note args, :indexing queue.
    {:ok, _} = new_job.args |> RewriteNoteLinks.new(queue: :indexing) |> Oban.insert()
    assert new_job.args["target_id"] == renamed.id

    assert %{failure: 0, success: 1} = Oban.drain_queue(queue: :indexing)
    assert authoritative!(user, src.id) == "see [[Fresh]]"
  end

  test "a late edge to a folder-moved note is repaired from the folder chain's row", ctx do
    %{user: user, vault: vault} = ctx
    [n1 | _] = seed_folder!(user, vault, "docs", 2)
    {:ok, _} = Engram.Folders.rename(user, vault, "docs", "archive")
    [folder_job] = all_enqueued(worker: RewriteNoteLinks)

    Repo.update_all(
      from(j in Oban.Job, where: j.worker == "Engram.Workers.RewriteNoteLinks"),
      set: [state: "completed", completed_at: DateTime.utc_now()]
    )

    {:ok, late} =
      Notes.upsert_note(user, vault, %{"path" => "Late.md", "content" => "see [[docs/n1]]"},
        actor: "api"
      )

    assert :ok = perform_job(ExtractNoteLinks, %{note_id: late.id})
    assert [repair] = all_enqueued(worker: RewriteNoteLinks)
    assert repair.args["sweep"] == true
    assert repair.args["target_id"] == n1.id
    entry = Enum.find(folder_job.args["targets"], &(&1["target_id"] == n1.id))
    assert repair.args["old_basename_hmac"] == entry["old_basename_hmac"]

    assert :ok = perform_job(RewriteNoteLinks, repair.args)
    assert authoritative!(user, late.id) == "see [[archive/n1]]"
  end
end
