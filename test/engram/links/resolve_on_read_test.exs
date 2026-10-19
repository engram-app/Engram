defmodule Engram.Links.ResolveOnReadTest do
  # Link targets are resolved when read, from the edge's name and the vault's
  # live notes. No job rewrites other notes' edges when a note appears or
  # goes away, so reads are right with nothing drained.
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Fixtures
  alias Engram.Links

  setup do
    {:ok, user} = Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    source = Fixtures.insert_note!(user, vault, %{path: "Source.md"})

    :ok =
      Links.replace_links(user, vault, source.id, [
        %{target: "Later", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
      ])

    %{user: user, vault: vault, source: source}
  end

  test "a note created after the link resolves with no job run", ctx do
    assert [%{dangling: true}] = Links.links_for_note(ctx.user, ctx.source.id)

    later = Fixtures.insert_note!(ctx.user, ctx.vault, %{path: "x/Later.md"})

    assert [%{target_note_id: id, target_path: "x/Later.md", dangling: false}] =
             Links.links_for_note(ctx.user, ctx.source.id)

    assert id == later.id
    assert [%{source_note_id: src}] = Links.backlinks_for_note(ctx.user, later.id)
    assert src == ctx.source.id
  end

  test "a deleted target goes dangling with no job run", ctx do
    later = Fixtures.insert_note!(ctx.user, ctx.vault, %{path: "Later.md"})
    :ok = Links.replace_links(ctx.user, ctx.vault, ctx.source.id, [edge("Later")])
    assert [%{target_note_id: id}] = Links.links_for_note(ctx.user, ctx.source.id)
    assert id == later.id

    {:ok, _} =
      Repo.with_tenant(ctx.user.id, fn ->
        Repo.update_all(from(n in Engram.Notes.Note, where: n.id == ^later.id),
          set: [deleted_at: DateTime.utc_now()]
        )
      end)

    assert [%{dangling: true, target_note_id: nil}] =
             Links.links_for_note(ctx.user, ctx.source.id)

    assert Links.backlinks_for_note(ctx.user, later.id) == []
  end

  test "creating a note enqueues no rebind job", ctx do
    {:ok, _} =
      Engram.Notes.upsert_note(ctx.user, ctx.vault, %{"path" => "Later.md", "content" => "# x"},
        actor: "api"
      )

    refute_enqueued(worker: Engram.Workers.RebindNoteLinks)
  end

  test "rows written before the resolution keys existed read the same", ctx do
    %{user: user, vault: vault} = ctx
    note = &Fixtures.insert_note!(user, vault, %{path: &1})

    hubs = Enum.map(~w(Hub.md a/Hub.md B/hub.md a/b/Hub.canvas Node.js.md x/Node.js.md), note)
    _att = Fixtures.insert_attachment!(user, vault, %{path: "img/Hub.png"})

    targets =
      ~w(Hub hub.md HUB.canvas a/hub b/HUB.md A/B/Hub.canvas Node.js x/node.js.md Hub.png missing/Hub)

    src = note.("Src.md")

    :ok =
      Links.replace_links(
        user,
        vault,
        src.id,
        targets |> Enum.with_index() |> Enum.map(fn {t, i} -> %{edge(t) | position: i} end)
      )

    read = fn ->
      {Links.links_for_note(user, src.id),
       Map.new(hubs, &{&1.id, Links.backlinks_for_note(user, &1.id)})}
    end

    keyed = read.()

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(Engram.Notes.Note, set: [path_ci_hmac: nil, path_length: nil])
        Repo.update_all(Engram.Attachments.Attachment, set: [path_ci_hmac: nil, path_length: nil])
        Repo.update_all(Engram.Links.NoteLink, set: [target_key_hmac: nil])
      end)

    assert read.() == keyed
    assert Enum.count(elem(keyed, 0), & &1.dangling) == 1
  end

  defp edge(target),
    do: %{target: target, alias: nil, anchor: nil, link_type: "wikilink", position: 0}
end
