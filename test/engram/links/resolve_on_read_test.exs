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
        Repo.update_all(Engram.Notes.Note,
          set: [path_ci_hmac: nil, path_length: nil, link_keys_stamp: nil]
        )

        Repo.update_all(Engram.Attachments.Attachment,
          set: [path_ci_hmac: nil, path_length: nil, link_keys_stamp: nil]
        )

        Repo.update_all(Engram.Links.NoteLink, set: [target_key_hmac: nil, link_keys_stamp: nil])
      end)

    assert read.() == keyed
    assert Enum.count(elem(keyed, 0), & &1.dangling) == 1
  end

  # The previous release renames a note mid-deploy: it re-encrypts the path
  # and recomputes the HMACs it knows, leaving the new keys describing the
  # OLD path. The fresh nonce breaks their stamp, so reads ignore them.
  test "keys a previous release left behind on rename are not trusted", ctx do
    %{user: user, vault: vault} = ctx
    note = Fixtures.insert_note!(user, vault, %{path: "a/Later.md"})
    _other = Fixtures.insert_note!(user, vault, %{path: "Later.md"})
    src = Fixtures.insert_note!(user, vault, %{path: "Src.md"})

    :ok =
      Links.replace_links(user, vault, src.id, [
        %{edge("b/Later") | position: 0},
        %{edge("Later") | position: 1}
      ])

    {:ok, dek} = Engram.Crypto.get_dek(user)
    {:ok, filter_key} = Engram.Crypto.dek_filter_key(user)
    new_path = "b/Later.md"

    # Fixture rows are legacy (dek_version 1): empty AAD.
    {ct, nonce} = Engram.Crypto.Envelope.encrypt(new_path, dek)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(from(n in Engram.Notes.Note, where: n.id == ^note.id),
          set: [
            path_ciphertext: ct,
            path_nonce: nonce,
            path_hmac: Engram.Crypto.hmac_field(filter_key, new_path)
          ]
        )
      end)

    assert [%{target_note_id: qualified}, %{target_note_id: bare}] =
             Links.links_for_note(user, src.id)

    assert qualified == note.id
    refute bare == note.id
    assert [%{source_note_id: s}] = Links.backlinks_for_note(user, note.id)
    assert s == src.id
  end

  test "a stale key's length cannot hide the shortest current note", ctx do
    winner = Fixtures.insert_note!(ctx.user, ctx.vault, %{path: "a/Hub.md"})
    stale = Fixtures.insert_note!(ctx.user, ctx.vault, %{path: "bb/hub.md"})
    :ok = Links.replace_links(ctx.user, ctx.vault, ctx.source.id, [edge("Hub")])

    # A writer that re-encrypted without restamping left a length shorter
    # than any real path.
    {:ok, _} =
      Repo.with_tenant(ctx.user.id, fn ->
        Repo.update_all(from(n in Engram.Notes.Note, where: n.id == ^stale.id),
          set: [path_length: 1, link_keys_stamp: "junk"]
        )
      end)

    assert [%{target_note_id: id}] = Links.links_for_note(ctx.user, ctx.source.id)
    assert id == winner.id
    assert [%{source_note_id: src}] = Links.backlinks_for_note(ctx.user, winner.id)
    assert src == ctx.source.id
  end

  test "batched reads answer exactly what per-note reads do", ctx do
    # Two notes share a basename, a third is unrelated, a fourth with the
    # same basename lives in another vault, one id has no row.
    a = Fixtures.insert_note!(ctx.user, ctx.vault, %{path: "a/index.md"})
    b = Fixtures.insert_note!(ctx.user, ctx.vault, %{path: "bb/index.md"})
    c = Fixtures.insert_note!(ctx.user, ctx.vault, %{path: "Later.md"})
    other_vault = insert(:vault, user: ctx.user)
    d = Fixtures.insert_note!(ctx.user, other_vault, %{path: "index.md"})
    d_src = Fixtures.insert_note!(ctx.user, other_vault, %{path: "Src.md"})
    missing = Ecto.UUID.generate()

    :ok =
      Links.replace_links(ctx.user, ctx.vault, ctx.source.id, [
        edge("index"),
        %{edge("bb/index") | position: 1},
        %{edge("Later") | position: 2},
        %{edge("Nowhere") | position: 3}
      ])

    :ok = Links.replace_links(ctx.user, ctx.vault, c.id, [edge("bb/index")])
    :ok = Links.replace_links(ctx.user, other_vault, d_src.id, [edge("index")])

    # c's edge predates the resolution keys, so it matches by decrypted text.
    corrupt(
      ctx.user,
      from(l in Engram.Links.NoteLink, where: l.source_note_id == ^c.id),
      target_key_hmac: nil,
      link_keys_stamp: nil
    )

    ids = [ctx.source.id, a.id, b.id, c.id, d.id, d_src.id, missing]

    for opts <- [[], [limit: 1], [distinct_sources: true]] do
      assert Links.backlinks_for_notes(ctx.user, ids, opts) ==
               Map.new(ids, &{&1, Links.backlinks_for_note(ctx.user, &1, opts)})
    end

    assert Links.links_for_notes(ctx.user, ids) ==
             Map.new(ids, &{&1, Links.links_for_note(ctx.user, &1)})

    sources =
      &(ctx.user |> Links.backlinks_for_note(&1) |> Enum.map(fn l -> l.source_note_id end))

    assert sources.(a.id) == [ctx.source.id]
    assert Enum.sort(sources.(b.id)) == Enum.sort([ctx.source.id, c.id])
    assert sources.(d.id) == [d_src.id]
  end

  # No stored target to fall back to: a name that will not decrypt resolves
  # to nothing.

  describe "undecryptable rows resolve to nothing" do
    import ExUnit.CaptureLog

    setup ctx do
      target = Fixtures.insert_note!(ctx.user, ctx.vault, %{path: "Later.md"})
      :ok = Links.replace_links(ctx.user, ctx.vault, ctx.source.id, [edge("Later")])
      %{target: target}
    end

    test "an edge whose text won't decrypt", ctx do
      corrupt(
        ctx.user,
        from(l in Engram.Links.NoteLink, where: l.source_note_id == ^ctx.source.id),
        target_text_ciphertext: <<0::128>>,
        target_key_hmac: nil,
        link_keys_stamp: nil
      )

      capture_log(fn ->
        assert [
                 %{
                   target_text: nil,
                   target_note_id: nil,
                   target_attachment_id: nil,
                   dangling: true
                 }
               ] = Links.links_for_note(ctx.user, ctx.source.id)

        # Unkeyed, so backlinks would have to match its text: none to match.
        assert Links.backlinks_for_note(ctx.user, ctx.target.id) == []
      end)
    end

    test "a note whose path won't decrypt", ctx do
      corrupt(ctx.user, from(n in Engram.Notes.Note, where: n.id == ^ctx.target.id),
        path_ciphertext: <<0::128>>
      )

      capture_log(fn ->
        assert Links.backlinks_for_note(ctx.user, ctx.target.id) == []
      end)
    end
  end

  defp corrupt(user, query, set) do
    {:ok, _} = Repo.with_tenant(user.id, fn -> Repo.update_all(query, set: set) end)
  end

  defp edge(target),
    do: %{target: target, alias: nil, anchor: nil, link_type: "wikilink", position: 0}
end
