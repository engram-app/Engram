defmodule Engram.Links.TargetCandidatesEquivalenceTest do
  # What link resolution answers through `Links.target_candidates/4`'s union,
  # pinned per call shape: bare names only, folder-qualified targets only, and
  # both. Recorded green on the six-part union (main 288d0d330), so any change
  # to which parts the union sends must keep every shape's answers exactly.
  # `resolve_target/4` (every same-name candidate decrypted and ranked, no
  # union) is a second, independent oracle.
  #
  # Every read runs as `engram_app` under `as_prod_role/1`, so RLS applies;
  # the tenant comes from the code's own `with_tenant`. The control proves the
  # role drop engaged (`docs/context/rls-enforcement-testing-traps.md`).
  # Not async: the role change is connection-wide.
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.Attachments.Attachment
  alias Engram.DataMigrations
  alias Engram.Fixtures
  alias Engram.Links
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Repo

  @notes ~w(Unique.md a/index.md F1/index.md F2/index.md F3/index.md hub.md Case/Hub.md
            Board.canvas Projects/Folder/Note.md Stale/Lone.md)
  @attachments ~w(img.png pics/photo.jpg old/scan.pdf)

  # target as written -> what it resolves to. Covers bare names (unique, a hub
  # of same-named notes, case variants, `.canvas`), folder-qualified targets
  # (exact, with extension, a suffix of a deeper path, a miss), renamed notes
  # and folders, attachments bare and qualified, rows with stale keys, a
  # dangling name, and a name only ANOTHER user's vault holds.
  @expected [
    {"Unique", {:note, "Unique.md"}},
    {"index", {:note, "a/index.md"}},
    {"HUB", {:note, "hub.md"}},
    {"Board", {:note, "Board.canvas"}},
    {"Projects/Folder/Note", {:note, "Projects/Folder/Note.md"}},
    {"Projects/Folder/Note.md", {:note, "Projects/Folder/Note.md"}},
    {"Folder/Note", {:note, "Projects/Folder/Note.md"}},
    {"Nope/Note", :dangling},
    {"Old", :dangling},
    {"New", {:note, "New.md"}},
    {"Moved/Deep", :dangling},
    {"Shifted/Deep", {:note, "Shifted/Deep.md"}},
    {"img.png", {:attachment, "img.png"}},
    {"pics/photo.jpg", {:attachment, "pics/photo.jpg"}},
    {"photo.jpg", {:attachment, "pics/photo.jpg"}},
    {"Lone", {:note, "Stale/Lone.md"}},
    {"Stale/Lone", {:note, "Stale/Lone.md"}},
    {"scan.pdf", {:attachment, "old/scan.pdf"}},
    {"Nowhere", :dangling},
    {"Bonly", :dangling}
  ]

  @answers Enum.map(@expected, &elem(&1, 1))

  @union ~r/FROM "notes".*UNION ALL/s

  # The table split by the union's call shape.
  @shapes [
    bare: Enum.reject(@expected, &String.contains?(elem(&1, 0), "/")),
    qualified: Enum.filter(@expected, &String.contains?(elem(&1, 0), "/")),
    mixed: @expected
  ]

  for ids? <- [true, false] do
    describe "ids mode #{ids?}" do
      setup do
        on_exit(fn ->
          Engram.Cache.clear_local(:note_split)
          DataMigrations.reset_cache()
        end)

        if unquote(ids?), do: :ok = DataMigrations.mark_done("note_split", 1)
        Engram.Cache.clear_local(:note_split)
        assert Notes.Keys.ids?() == unquote(ids?)

        a = corpus!(@notes, @attachments)
        b = corpus!(~w(Unique.md Only/Bonly.md), ~w(img.png))
        %{a: a, b: b}
      end

      test "links, backlinks and danglers of the mixed call match the six-part union", %{a: a} do
        links = 1..8 |> Enum.map(fn _ -> prod_links!(a) end) |> Enum.uniq()
        assert [answers] = links, "repeated calls disagreed: #{inspect(links)}"
        assert answers == @answers

        for {target, want} <- @expected do
          got =
            case Links.resolve_target(a.user, a.vault, target, "wikilink") do
              {kind, id} -> {kind, Map.fetch!(a.paths, id)}
              :dangling -> :dangling
            end

          assert got == want, "resolve_target/4 disagrees on #{target}: #{inspect(got)}"
        end

        assert {:returned, backlinks} =
                 as_prod_role(fn -> Links.backlinks_for_notes(a.user, Map.keys(a.notes)) end)

        for {id, path} <- a.notes do
          want = Enum.count(@expected, &(elem(&1, 1) == {:note, path}))
          assert length(Map.fetch!(backlinks, id)) == want, "backlinks of #{path}"
        end

        parsed = Enum.map(@expected, &%{target: elem(&1, 0)})
        hmacs = Enum.map(parsed, &Links.basename_hmac(a.user, Links.basename_key(&1.target)))

        dangling =
          for {{_, :dangling}, hmac} <- Enum.zip(@expected, hmacs), uniq: true, do: hmac

        assert {:returned, got} =
                 as_prod_role(fn -> Links.dangling_basenames(a.user, a.vault, parsed, hmacs) end)

        assert Enum.sort(got) == Enum.sort(dangling)
      end

      test "each call shape answers as the six-part union", %{a: a} do
        for {shape, rows} <- @shapes do
          link!(a, Enum.map(rows, &elem(&1, 0)))
          {runs, _sql} = shape_runs(a)

          assert runs == [Enum.map(rows, &elem(&1, 1))],
                 "#{shape} call: #{inspect(runs)}"
        end
      end

      test "a statement warmed by one tenant answers the next with only its rows",
           %{a: a, b: b} do
        for _ <- 1..8, do: assert(prod_links!(a) == @answers)

        assert prod_links!(b, ["Unique", "img.png", "Bonly", "index"]) ==
                 [
                   {:note, "Unique.md"},
                   {:attachment, "img.png"},
                   {:note, "Only/Bonly.md"},
                   :dangling
                 ]
      end

      test "control: the union under the dropped role with no tenant sees zero rows",
           %{a: a} do
        {_, queries} = Engram.QueryRecorder.record(fn -> prod_links!(a) end)
        me = self()

        %{sql: sql, params: params} =
          queries
          |> Enum.filter(&(&1.pid == me and &1.sql =~ @union))
          |> List.last()

        # The statement matches rows (as the superuser, RLS bypassed), so zero
        # rows under the role is the policy, not a query that matches nothing.
        assert Repo.query!(sql, params).num_rows > 0

        assert {:returned, %{num_rows: 0}} = as_prod_role(fn -> Repo.query!(sql, params) end),
               "the union saw rows as engram_app with no tenant: the role drop never engaged"
      end
    end
  end

  # A vault holding `notes` and `attachments` (and the source), plus `Old.md` renamed to
  # `New.md` and `Moved/Deep.md` moved by a folder rename to `Shifted/`
  # after the source linked them, and `Stale/Lone.md` / `old/scan.pdf` with
  # their resolution keys stale.
  defp corpus!(notes, attachments) do
    {:ok, user} = Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    ids = Fixtures.insert_notes!(user, vault, Enum.map(notes ++ ["zz/Source.md"], &%{path: &1}))
    {note_ids, [src]} = Enum.split(ids, -1)
    att_ids = Fixtures.insert_attachments!(user, vault, Enum.map(attachments, &%{path: &1}))

    moved =
      for {path, renamed} <- [{"Old.md", "New.md"}, {"Moved/Deep.md", "Shifted/Deep.md"}],
          into: %{} do
        {:ok, note} =
          Notes.upsert_note(user, vault, %{"path" => path, "content" => "x"}, actor: "api")

        {note.id, renamed}
      end

    ctx = %{user: user, vault: vault, src: src}
    link!(ctx, Enum.map(@expected, &elem(&1, 0)))

    {:ok, _} = Notes.rename_note(user, vault, "Old.md", "New.md")
    {:ok, _} = Notes.rename_folder(user, vault, "Moved", "Shifted")
    stale!(user, Note, Enum.zip(note_ids, notes), "Stale/Lone.md")
    stale!(user, Attachment, Enum.zip(att_ids, attachments), "old/scan.pdf")

    notes = Map.merge(Map.new(Enum.zip(note_ids, notes)), moved)
    paths = Map.merge(notes, Map.new(Enum.zip(att_ids, attachments)))
    Map.merge(ctx, %{notes: notes, paths: paths})
  end

  defp link!(%{user: u, vault: v, src: src}, targets) do
    :ok =
      Links.replace_links(
        u,
        v,
        src,
        targets
        |> Enum.with_index()
        |> Enum.map(fn {t, i} ->
          %{target: t, alias: nil, anchor: nil, link_type: "wikilink", position: i}
        end)
      )
  end

  # Keys a writer left behind: missing, so the row reads through the
  # `stale` part only.
  defp stale!(user, schema, pairs, path) do
    set = [link_keys_stamp: nil, path_ci_hmac: nil]
    set = if schema == Note, do: [{:link_keys_v, nil} | set], else: set

    for {id, ^path} <- pairs do
      {:ok, {1, _}} =
        Repo.with_tenant(user.id, fn ->
          Repo.update_all(from(r in schema, where: r.id == ^id), set: set)
        end)
    end
  end

  # 8 calls' distinct answers, and the union the last one sent.
  defp shape_runs(ctx) do
    me = self()
    {runs, queries} = Engram.QueryRecorder.record(fn -> for _ <- 1..8, do: prod_links!(ctx) end)
    union = queries |> Enum.filter(&(&1.pid == me and &1.sql =~ @union)) |> List.last()
    {Enum.uniq(runs), union.sql}
  end

  # `links_for_note/2` as `engram_app`, each link as what it resolves to.
  defp prod_links!(ctx, targets \\ nil) do
    if targets, do: link!(ctx, targets)

    {:returned, links} = as_prod_role(fn -> Links.links_for_note(ctx.user, ctx.src) end)

    Enum.map(links, fn
      %{target_note_id: nil, target_attachment_id: nil} -> :dangling
      %{target_note_id: nil, target_attachment_id: id} -> {:attachment, ctx.paths[id]}
      %{target_note_id: id} -> {:note, ctx.paths[id]}
    end)
  end
end
