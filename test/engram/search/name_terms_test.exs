defmodule Engram.Search.NameTermsTest do
  @moduledoc """
  S1, the Postgres name leg (`Engram.Search.NameTerms`). After a rename the
  Qdrant vectors keep the old title and folder words (R3a writes nothing to
  Qdrant on rename), so here Qdrant answers NOTHING for the new name unless a
  test says otherwise: a hit can only come from the leg.
  """
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.RlsCase

  alias Engram.Bookkeeping.Drain
  alias Engram.Crypto
  alias Engram.Crypto.UserDekRotation
  alias Engram.DataMigrations
  alias Engram.DataMigrations.NameTerms, as: Ledger
  alias Engram.Folders.Folder
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.QueryPlan
  alias Engram.QueryRecorder
  alias Engram.Repo
  alias Engram.Search
  alias Engram.Search.NameTerms
  alias Engram.Search.NameTerms.Row
  alias Engram.ServiceConfig
  alias Engram.Workers.BackfillNameTerms

  defmodule ScopeFilter do
    @moduledoc false
    # The note-filter seam: the test process names the in-scope note ids.
    @keys ~w(folder tags type)a
    def any?(opts), do: Enum.any?(opts, fn {k, v} -> k in @keys and v not in [nil, [], ""] end)

    def resolve(_user, _vaults, _filter, opts) do
      ids = Process.get(:in_scope, [])

      case Keyword.get(opts, :within) do
        nil -> {:ok, {:ids, ids}}
        within -> {:ok, {:ids, Enum.filter(within, &(&1 in ids))}}
      end
    end
  end

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    Engram.Cache.clear_local(:note_id_filter)
    on_exit(fn -> Engram.Cache.clear_local(:note_id_filter) end)
    test_pid = self()
    {:ok, answer} = Agent.start_link(fn -> [] end)

    # Every ranked query: the points the test put in `answer` (none by default).
    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      send(test_pid, :qdrant_called)
      points = Agent.get(answer, & &1)
      json(conn, %{"result" => %{"points" => points}})
    end)

    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/scroll", fn conn ->
      json(conn, %{"result" => %{"points" => [], "next_page_offset" => nil}})
    end)

    Bypass.stub(bypass, "GET", "/collections/engram_notes", fn conn ->
      json(conn, %{
        "status" => "ok",
        "result" => %{"status" => "green", "payload_schema" => %{"n" => %{"data_type" => "uuid"}}}
      })
    end)

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Names", Ecto.UUID.generate())
    %{user: user, vault: vault, bypass: bypass, answer: answer}
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  defp write!(user, vault, path, content \\ "lab results") do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    note
  end

  # A note as the index pass leaves it: a chunk point and its name terms.
  defp indexed!(user, note) do
    point = Ecto.UUID.generate()
    Engram.Fixtures.insert_chunk!(user, note, point, text: "lab results", heading: "")
    :ok = NameTerms.on_note_written(user, note)
    point
  end

  defp keyword(user, vault, query, opts \\ []) do
    {:ok, hits} = Search.search(user, vault, query, [mode: :keyword, limit: 5] ++ opts)
    hits
  end

  defp rows(ref_id) do
    Repo.all(from(r in Row, where: r.ref_id == ^ref_id), skip_tenant_check: true)
  end

  defp stamp(note_id) do
    Repo.query!("SELECT name_terms_stamp FROM notes WHERE id = $1", [Ecto.UUID.dump!(note_id)]).rows
    |> hd()
    |> hd()
  end

  defp dead_rows!(user, vault, dim, n) do
    rows =
      for _ <- 1..n,
          do: %{
            vault_id: vault.id,
            dim: dim,
            ref_kind: 0,
            # All before any live note's id in posting order.
            ref_id: "00000000-" <> String.slice(Ecto.UUID.generate(), 9..-1//1),
            user_id: user.id
          }

    {:ok, _} = Repo.with_tenant(user.id, fn -> Repo.insert_all(Row, rows) end)
  end

  defp tenant(user, fun) do
    {:ok, result} = Repo.with_tenant(user.id, fun)
    result
  end

  describe "the leg finds renamed names" do
    test "a renamed note is found by its NEW title though Qdrant holds the old one", ctx do
      note = write!(ctx.user, ctx.vault, "Health/Iron.md")
      point = indexed!(ctx.user, note)

      {:ok, renamed} =
        Notes.rename_note(ctx.user, ctx.vault, "Health/Iron.md", "Health/Ferritin Levels.md")

      assert renamed.id == note.id

      hits = keyword(ctx.user, ctx.vault, "ferritin")
      assert_received :qdrant_called
      assert Enum.map(hits, & &1.qdrant_id) == [point]
      assert hd(hits).source_path == "Health/Ferritin Levels.md"

      # The old name's terms are gone: only that note's rows were replaced.
      assert keyword(ctx.user, ctx.vault, "iron") == []
    end

    test "the leg is on before the backfill has finished", ctx do
      note = write!(ctx.user, ctx.vault, "Iron.md")
      point = indexed!(ctx.user, note)
      _other = write!(ctx.user, ctx.vault, "Unwritten.md")
      {:ok, _} = Notes.rename_note(ctx.user, ctx.vault, "Iron.md", "Ferritin.md")

      refute Ledger.done?()
      assert Enum.map(keyword(ctx.user, ctx.vault, "ferritin"), & &1.qdrant_id) == [point]
    end

    test "a renamed folder is found by its new name, through notes at any depth", ctx do
      a = write!(ctx.user, ctx.vault, "Projects/a.md")
      b = write!(ctx.user, ctx.vault, "Projects/Deep/Deeper/b.md")
      pa = indexed!(ctx.user, a)
      pb = indexed!(ctx.user, b)

      assert {:ok, _} = Notes.rename_folder(ctx.user, ctx.vault, "Projects", "Zanzibar")

      assert keyword(ctx.user, ctx.vault, "zanzibar") |> Enum.map(& &1.qdrant_id) |> Enum.sort() ==
               Enum.sort([pa, pb])

      # The old folder name no longer matches through name_terms.
      assert keyword(ctx.user, ctx.vault, "projects") == []
    end

    test "the name_terms_search override turns the leg off", ctx do
      note = write!(ctx.user, ctx.vault, "Ferritin.md")
      indexed!(ctx.user, note)
      ServiceConfig.put_override(:name_terms_search, false)
      assert keyword(ctx.user, ctx.vault, "ferritin") == []
    end

    test "a filtered search keeps every in-scope Qdrant hit", ctx do
      ServiceConfig.put_override(:note_filter, ScopeFilter)

      in_scope =
        for i <- 1..5 do
          note = write!(ctx.user, ctx.vault, "In/n#{i}.md")
          {note, indexed!(ctx.user, note)}
        end

      # Ten out-of-scope notes the name leg matches.
      for i <- 1..10, do: indexed!(ctx.user, write!(ctx.user, ctx.vault, "Out/zeta #{i}.md"))

      Process.put(:in_scope, Enum.map(in_scope, &elem(&1, 0).id))

      Agent.update(ctx.answer, fn _ ->
        for {{_n, p}, i} <- Enum.with_index(in_scope), do: %{"id" => p, "score" => 10 - i}
      end)

      hits = keyword(ctx.user, ctx.vault, "zeta", folder: "In")

      assert Enum.map(hits, & &1.qdrant_id) == Enum.map(in_scope, &elem(&1, 1))
    end
  end

  describe "dead refs" do
    test "a trashed note never surfaces, and its delete hook drops its rows", ctx do
      note = write!(ctx.user, ctx.vault, "Ferritin.md")
      indexed!(ctx.user, note)
      assert rows(note.id) != []

      :ok = Notes.delete_note(ctx.user, ctx.vault, "Ferritin.md")
      # Rows still there (the delete job has not run): the read skips them.
      assert keyword(ctx.user, ctx.vault, "ferritin") == []

      :ok = NameTerms.on_note_deleted(ctx.user.id, note.id)
      assert rows(note.id) == []
      assert stamp(note.id) == nil
    end

    test "a purged note never surfaces, and the drain sweeps its orphan rows", ctx do
      note = write!(ctx.user, ctx.vault, "Ferritin.md")
      indexed!(ctx.user, note)
      Repo.query!("DELETE FROM notes WHERE id = $1", [Ecto.UUID.dump!(note.id)])

      assert NameTerms.recall(ctx.user, {:vault, ctx.vault}, "ferritin") == []
      assert %{name_terms_orphans: removed} = Drain.run()
      assert removed > 0
      assert rows(note.id) == []
    end

    test "a live renamed note surfaces though 600 dead rows share its term", ctx do
      {:ok, fk} = Crypto.dek_filter_key(ctx.user)
      [dim] = NameTerms.dims(["common"], fk)
      note = write!(ctx.user, ctx.vault, "Old.md")
      point = indexed!(ctx.user, note)
      {:ok, _} = Notes.rename_note(ctx.user, ctx.vault, "Old.md", "common.md")
      dead_rows!(ctx.user, ctx.vault, dim, 600)

      assert [%{qdrant_id: ^point}] = NameTerms.recall(ctx.user, {:vault, ctx.vault}, "common")
      # Through the postings, not only the exact-filename probe.
      nid = note.id
      assert [{^nid, 1}] = tenant(ctx.user, fn -> NameTerms.hits([ctx.vault.id], [dim], 0) end)
    end

    test "3,000 dead rows: the scan stops at its cap, counts it, and the sweep restores recall",
         ctx do
      {:ok, fk} = Crypto.dek_filter_key(ctx.user)
      [dim] = NameTerms.dims(["common"], fk)
      note = write!(ctx.user, ctx.vault, "common.md")
      point = indexed!(ctx.user, note)
      dead_rows!(ctx.user, ctx.vault, dim, 3_000)

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "#{inspect(ref)}",
        [:engram, :search, :name_terms, :scan_capped],
        fn _e, m, meta, _ -> send(test_pid, {ref, m, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("#{inspect(ref)}") end)

      # Honest limit: 2,000 postings scanned, all dead, before the live one.
      # Bounded and counted; the note's exact-filename probe still finds it.
      assert [%{qdrant_id: ^point}] = NameTerms.recall(ctx.user, {:vault, ctx.vault}, "common")
      assert_received {^ref, %{count: 1}, %{kind: 0}}
      assert tenant(ctx.user, fn -> NameTerms.hits([ctx.vault.id], [dim], 0) end) == []

      # The orphan sweep removes the dead rows; the term reads the note again.
      sweep = fn sweep, after_id ->
        case tenant(ctx.user, fn -> NameTerms.sweep_orphans(Repo, after_id) end) do
          {500, last, _} -> sweep.(sweep, last)
          _ -> :ok
        end
      end

      sweep.(sweep, nil)
      assert [{id, 1}] = tenant(ctx.user, fn -> NameTerms.hits([ctx.vault.id], [dim], 0) end)
      assert id == note.id
    end
  end

  describe "bounds" do
    test "33 distinct terms write 32 rows", ctx do
      words = for i <- 1..33, do: "w#{i}x"
      note = write!(ctx.user, ctx.vault, Enum.join(words, " ") <> ".md", "")
      :ok = NameTerms.on_note_written(ctx.user, note)

      assert length(rows(note.id)) == NameTerms.max_terms()
      assert NameTerms.max_terms() == 32
    end

    test "a query reads at most 16 terms", ctx do
      words = for c <- ?a..?t, do: "q" <> <<c>>
      late = write!(ctx.user, ctx.vault, "#{List.last(words)}.md")
      early = write!(ctx.user, ctx.vault, "#{hd(words)}.md")
      indexed!(ctx.user, late)
      pe = indexed!(ctx.user, early)

      {:ok, fk} = Crypto.dek_filter_key(ctx.user)
      assert length(NameTerms.dims([Enum.join(words, " ")], fk, 16)) == 16

      # The 20th word is past the cap: only the first word's note is read.
      assert [%{qdrant_id: ^pe}] =
               NameTerms.recall(ctx.user, {:vault, ctx.vault}, Enum.join(words, " "))
    end

    test "a term with more than 500 live postings reads 500", ctx do
      {:ok, fk} = Crypto.dek_filter_key(ctx.user)
      [alpha, _] = a_dims = NameTerms.dims(["alpha zebra"], fk)
      [beta, _] = b_dims = NameTerms.dims(["beta yak"], fk)

      # Live fillers posted on `alpha` (499) and `beta` (501) only, then the
      # targets: UUIDv7 ids, so every filler precedes them in posting order.
      postings!(ctx.user, ctx.vault, alpha, 499)
      postings!(ctx.user, ctx.vault, beta, 501)
      a = write!(ctx.user, ctx.vault, "alpha zebra.md")
      b = write!(ctx.user, ctx.vault, "beta yak.md")
      for n <- [a, b], do: :ok = NameTerms.on_note_written(ctx.user, n)
      hits = &tenant(ctx.user, fn -> NameTerms.hits([ctx.vault.id], &1, 0) end)
      {aid, bid} = {a.id, b.id}

      # 499 + the target = 500 `alpha` postings: both terms read, it ranks first.
      assert [{^aid, 2} | _] = hits.(a_dims)

      # 501 fillers: `beta`'s 500 stop before the target; only `yak` counts.
      b_hits = hits.(b_dims)
      refute Enum.any?(b_hits, &match?({^bid, 2}, &1))
      assert length(b_hits) == 50
    end

    test "folder postings have their own budget", ctx do
      {:ok, fk} = Crypto.dek_filter_key(ctx.user)
      [dim] = NameTerms.dims(["Zanzibar"], fk)
      # 600 notes' postings on the same word, before the folder's in time.
      postings!(ctx.user, ctx.vault, dim, 600)
      note = write!(ctx.user, ctx.vault, "Zanzibar/inside.md")
      point = indexed!(ctx.user, note)

      assert [_folder] = tenant(ctx.user, fn -> NameTerms.hits([ctx.vault.id], [dim], 1) end)

      assert point in Enum.map(
               NameTerms.recall(ctx.user, {:vault, ctx.vault}, "zanzibar"),
               & &1.id
             )
    end

    test "a folder reaches at most 50 notes, newest first", ctx do
      notes = for i <- 1..60, do: write!(ctx.user, ctx.vault, "Bulk/n#{i}.md")

      [folder] =
        Repo.all(from(f in Folder, where: f.user_id == ^ctx.user.id), skip_tenant_check: true)

      got = tenant(ctx.user, fn -> NameTerms.under_folders([ctx.vault.id], [folder.id]) end)

      assert got == notes |> Enum.map(& &1.id) |> Enum.sort(:desc) |> Enum.take(50)
    end

    test "a move keeps the basename and writes no name terms", ctx do
      note = write!(ctx.user, ctx.vault, "A/x.md")
      # The target folder exists already: creating it would write its terms.
      write!(ctx.user, ctx.vault, "B/other.md")
      :ok = NameTerms.on_note_written(ctx.user, note)
      before = {rows(note.id), stamp(note.id)}

      {{:ok, _}, queries} =
        QueryRecorder.record(fn -> Notes.rename_note(ctx.user, ctx.vault, "A/x.md", "B/x.md") end)

      refute Enum.any?(queries, &(&1.sql =~ ~r/(INSERT INTO|DELETE FROM) "name_terms"/))
      refute Enum.any?(queries, &(&1.sql =~ ~r/"name_terms_stamp" =/))
      assert {rows(note.id), stamp(note.id)} == before
    end

    test "inside a transaction a failing write rolls back only itself", ctx do
      note = write!(ctx.user, ctx.vault, "Ferritin.md")
      # A vault that does not exist: the term insert violates its foreign key.
      bad = %{note | vault_id: Ecto.UUID.generate()}

      {:ok, :alive} =
        Repo.with_tenant(ctx.user.id, fn ->
          :ok = NameTerms.on_note_written(ctx.user, bad)
          %{rows: [[1]]} = Repo.query!("SELECT 1")
          :alive
        end)
    end
  end

  describe "query plans (index-bounded)" do
    setup ctx do
      for i <- 1..50,
          do: indexed!(ctx.user, write!(ctx.user, ctx.vault, "P#{rem(i, 5)}/n#{i}.md"))

      :ok
    end

    test "postings read the primary key and probe each ref by its key", ctx do
      for {kind, ref_pkey} <- [{0, "notes_pkey"}, {1, "folders_pkey"}] do
        {sql, _} = Repo.to_sql(:all, NameTerms.hits_query([ctx.vault.id], [1, 2], kind))
        plan = QueryPlan.generic_plan(sql, analyze: ["name_terms", "notes", "folders"])
        assert plan =~ "name_terms_pkey", plan
        assert plan =~ ref_pkey, plan
        assert plan =~ "Limit", plan
      end
    end

    test "folder notes read notes_folder_ref_live_id", ctx do
      {sql, _} =
        Repo.to_sql(
          :all,
          from(n in Note,
            where:
              n.vault_id == ^ctx.vault.id and n.folder_ref_id == ^Ecto.UUID.generate() and
                n.kind == "note" and is_nil(n.deleted_at),
            order_by: [desc: n.id],
            limit: 50,
            select: n.id
          )
        )

      plan =
        QueryPlan.generic_plan(sql,
          analyze: ["notes"],
          fresh: true,
          bitmapscan: false,
          all_visible: true
        )

      # Read backward in id order: no sort, at most 50 entries per folder.
      assert plan =~ "using notes_folder_ref_live_id on", plan
      refute plan =~ "Sort", plan
    end
  end

  describe "self-heal and rotation" do
    test "the backfill chain heals refs a previous release left unwritten, then the ledger closes",
         ctx do
      note = write!(ctx.user, ctx.vault, "Inbox/Ferritin.md")
      assert rows(note.id) == []

      assert {:more, _} = Ledger.run_pass()
      assert [%{args: args}] = all_enqueued(worker: BackfillNameTerms)
      # Each hop is taken off the queue first, as Oban does, so its successor
      # is not a unique conflict.
      Repo.delete_all(Oban.Job)
      assert :ok = perform_job(BackfillNameTerms, Map.put(args, "pause_ms", 0))
      [%{args: next}] = all_enqueued(worker: BackfillNameTerms)
      assert next["table"] == "folders"
      Repo.delete_all(Oban.Job)
      assert :ok = perform_job(BackfillNameTerms, Map.put(next, "pause_ms", 0))
      assert all_enqueued(worker: BackfillNameTerms) == []

      assert rows(note.id) != []
      assert :done = Ledger.run_pass()
    end

    test "a hop stops on its time budget and resumes at its cursor", ctx do
      for i <- 1..3, do: write!(ctx.user, ctx.vault, "n#{i}.md")

      :ok = perform_job(BackfillNameTerms, %{"table" => "notes", "hop_ms" => 0, "pause_ms" => 0})

      assert [%{args: %{"after" => after_id, "table" => "notes"}}] =
               all_enqueued(worker: BackfillNameTerms)

      assert is_binary(after_id)
    end

    test "a previous-release write (no terms, stale stamp) is healed by the drain", ctx do
      note = write!(ctx.user, ctx.vault, "Iron.md")
      :ok = NameTerms.on_note_written(ctx.user, note)
      :ok = DataMigrations.mark_done(Ledger.name(), Ledger.version())

      Repo.query!("UPDATE notes SET name_terms_stamp = NULL WHERE id = $1", [
        Ecto.UUID.dump!(note.id)
      ])

      Repo.query!("DELETE FROM name_terms WHERE ref_id = $1", [Ecto.UUID.dump!(note.id)])

      assert ctx.user.id in Drain.candidates(:name_terms)
      assert %{name_terms: 1} = Drain.run()
      refute ctx.user.id in Drain.candidates(:name_terms)
      assert rows(note.id) != []
    end

    test "DEK rotation rewrites the user's rows under the new key", ctx do
      note = write!(ctx.user, ctx.vault, "Folder One/Ferritin.md")
      :ok = NameTerms.on_note_written(ctx.user, note)
      before = rows(note.id) |> Enum.map(& &1.dim) |> Enum.sort()
      assert before != []

      assert :ok = UserDekRotation.rotate_user(ctx.user.id)

      user = Engram.Accounts.get_user_uncached(ctx.user.id)
      {:ok, fk} = Crypto.dek_filter_key(user)
      expected = NameTerms.dims(["Ferritin", "Ferritin"], fk) |> Enum.sort()

      assert rows(note.id) |> Enum.map(& &1.dim) |> Enum.sort() == expected
      refute expected == before

      folder_dims =
        from(r in Row, where: r.ref_kind == 1 and r.user_id == ^user.id, select: r.dim)
        |> Repo.all(skip_tenant_check: true)
        |> Enum.sort()

      assert folder_dims == Enum.sort(NameTerms.dims(["Folder One"], fk))
      refute ctx.user.id in Drain.candidates(:name_terms)
    end
  end

  describe "RLS" do
    setup ctx do
      note = write!(ctx.user, ctx.vault, "Ferritin.md")
      :ok = NameTerms.on_note_written(ctx.user, note)
      %{note: note}
    end

    test "control: the dropped role sees zero rows", %{note: note} do
      assert rows(note.id) != []

      assert as_prod_role(fn ->
               Repo.one(from(r in Row, where: r.ref_id == ^note.id, select: count(r.ref_id)),
                 skip_tenant_check: true
               )
             end) == {:returned, 0}
    end

    test "the leg's read is tenant-scoped: another tenant reads none of the rows", ctx do
      {:ok, fk} = Crypto.dek_filter_key(ctx.user)
      dims = NameTerms.dims(["Ferritin"], fk)
      {:ok, other} = Engram.Fixtures.user_with_dek_fixture()

      read = fn tenant ->
        as_prod_role(fn ->
          {:ok, hits} =
            Repo.with_tenant(tenant, fn -> NameTerms.hits([ctx.vault.id], dims, 0) end)

          hits
        end)
      end

      assert {:returned, [{id, _}]} = read.(ctx.user.id)
      assert id == ctx.note.id
      assert read.(other.id) == {:returned, []}
    end
  end

  # `n` live notes in `vault` (bulk fixture), each with one posting on `dim`.
  defp postings!(user, vault, dim, n) do
    ids =
      Engram.Fixtures.insert_notes!(
        user,
        vault,
        for(i <- 1..n, do: %{"path" => "filler/#{dim}-#{i}.md", "content" => "x"})
      )

    rows =
      for id <- ids,
          do: %{vault_id: vault.id, dim: dim, ref_kind: 0, ref_id: id, user_id: user.id}

    {:ok, _} = Repo.with_tenant(user.id, fn -> Repo.insert_all(Row, rows) end)
  end
end
