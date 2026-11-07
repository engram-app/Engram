defmodule Engram.Search.NameTermsTest do
  @moduledoc """
  S1, the Postgres name leg (`Engram.Search.NameTerms`). After a rename the
  Qdrant vectors keep the old title and folder words (R3a writes nothing to
  Qdrant on rename), so here Qdrant answers NOTHING for the new name: a hit
  can only come from the leg.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Bookkeeping.Drain
  alias Engram.Crypto
  alias Engram.Crypto.UserDekRotation
  alias Engram.DataMigrations
  alias Engram.DataMigrations.NameTerms, as: Ledger
  alias Engram.Folders.Folder
  alias Engram.Notes
  alias Engram.Repo
  alias Engram.Search
  alias Engram.Search.NameTerms
  alias Engram.Search.NameTerms.Row
  alias Engram.ServiceConfig

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    test_pid = self()

    # Every ranked query and scroll: nothing (the vectors hold the old name).
    for path <- ~w(/collections/engram_notes/points/query /collections/engram_notes/points/scroll) do
      Bypass.stub(bypass, "POST", path, fn conn ->
        send(test_pid, :qdrant_called)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"result" => %{"points" => [], "next_page_offset" => nil}})
        )
      end)
    end

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Names", Ecto.UUID.generate())
    %{user: user, vault: vault, bypass: bypass}
  end

  defp write!(user, vault, path, content \\ "lab results") do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    note
  end

  defp indexed!(user, note) do
    point = Ecto.UUID.generate()
    Engram.Fixtures.insert_chunk!(user, note, point, text: "lab results", heading: "")
    point
  end

  defp done!, do: DataMigrations.mark_done(Ledger.name(), Ledger.version())

  defp keyword(user, vault, query) do
    {:ok, hits} = Search.search(user, vault, query, mode: :keyword, limit: 5)
    hits
  end

  defp rows(ref_id) do
    Repo.all(from(r in Row, where: r.ref_id == ^ref_id), skip_tenant_check: true)
  end

  defp seed_terms!(user, note), do: :ok = NameTerms.on_note_written(user, note)

  describe "the leg finds renamed names" do
    test "a renamed note is found by its NEW title though Qdrant holds the old one", ctx do
      note = write!(ctx.user, ctx.vault, "Health/Iron.md")
      point = indexed!(ctx.user, note)
      done!()

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

    test "a renamed folder is found by its new name, through its notes", ctx do
      a = write!(ctx.user, ctx.vault, "Projects/a.md")
      b = write!(ctx.user, ctx.vault, "Projects/b.md")
      pa = indexed!(ctx.user, a)
      pb = indexed!(ctx.user, b)
      done!()

      assert {:ok, _} = Notes.rename_folder(ctx.user, ctx.vault, "Projects", "Zanzibar")

      assert keyword(ctx.user, ctx.vault, "zanzibar") |> Enum.map(& &1.qdrant_id) |> Enum.sort() ==
               Enum.sort([pa, pb])

      # The old folder name no longer matches through name_terms.
      assert keyword(ctx.user, ctx.vault, "projects") == []

      # The rename wrote the folder's rows only: its notes' terms stay unwritten.
      assert rows(a.id) == []
    end

    test "before the ledger is done the leg is off and search is unchanged", ctx do
      note = write!(ctx.user, ctx.vault, "Iron.md")
      indexed!(ctx.user, note)
      {:ok, _} = Notes.rename_note(ctx.user, ctx.vault, "Iron.md", "Ferritin.md")

      refute Ledger.done?()
      assert keyword(ctx.user, ctx.vault, "ferritin") == []
    end

    test "the name_terms_search override turns the leg off", ctx do
      note = write!(ctx.user, ctx.vault, "Ferritin.md")
      indexed!(ctx.user, note)
      {:ok, _} = Notes.rename_note(ctx.user, ctx.vault, "Ferritin.md", "Ferritin Two.md")
      done!()
      ServiceConfig.put_override(:name_terms_search, false)
      assert keyword(ctx.user, ctx.vault, "ferritin") == []
    end
  end

  describe "bounds" do
    test "33 distinct terms write 32 rows", ctx do
      words = for i <- 1..33, do: "w#{i}x"
      note = write!(ctx.user, ctx.vault, Enum.join(words, " ") <> ".md", "")
      seed_terms!(ctx.user, note)

      assert length(rows(note.id)) == NameTerms.max_terms()
      assert NameTerms.max_terms() == 32
    end

    test "a term with more than 500 postings reads 500", ctx do
      {:ok, fk} = Crypto.dek_filter_key(ctx.user)
      target = write!(ctx.user, ctx.vault, "common zebra.md")
      seed_terms!(ctx.user, target)
      dims = NameTerms.dims(["common zebra"], fk)
      [common, _zebra] = dims
      tid = target.id

      # Fillers on `common` only, all before the target in posting order.
      fill = fn n ->
        rows =
          for _ <- 1..n,
              do: %{
                vault_id: ctx.vault.id,
                dim: common,
                ref_kind: 0,
                ref_id: "00000000-" <> String.slice(Ecto.UUID.generate(), 9..-1//1),
                user_id: ctx.user.id
              }

        {:ok, _} = Repo.with_tenant(ctx.user.id, fn -> Repo.insert_all(Row, rows) end)
      end

      hits = fn ->
        {:ok, hits} =
          Repo.with_tenant(ctx.user.id, fn -> NameTerms.hits([ctx.vault.id], dims) end)

        hits
      end

      # 499 + the target = 500 `common` postings: both terms read, it ranks first.
      fill.(499)
      assert [{0, ^tid, 2} | _] = hits.()

      # 501 fillers: `common`'s 500 read stop before the target; only `zebra` counts.
      fill.(2)
      refute Enum.any?(hits.(), &match?({0, ^tid, 2}, &1))
      assert length(hits.()) == 50
    end
  end

  describe "self-heal and rotation" do
    test "the ledger heals refs a previous release left unwritten, then closes", ctx do
      note = write!(ctx.user, ctx.vault, "Inbox/Ferritin.md")
      assert rows(note.id) == []

      assert {:more, _} = Ledger.run_pass()
      assert rows(note.id) != []

      [%{name_terms_stamp: <<1, _::binary>>}] =
        Repo.all(from(f in Folder, where: f.user_id == ^ctx.user.id), skip_tenant_check: true)

      assert :done = Ledger.run_pass()
    end

    test "a previous-release write (no terms, stale stamp) is healed by the drain", ctx do
      note = write!(ctx.user, ctx.vault, "Iron.md")
      Ledger.run_pass()
      Ledger.run_pass()
      done!()

      # What a release without the hook leaves: the stamp behind the hmac.
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
      Ledger.run_pass()
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
      Ledger.run_pass()
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
          {:ok, hits} = Repo.with_tenant(tenant, fn -> NameTerms.hits([ctx.vault.id], dims) end)
          hits
        end)
      end

      assert {:returned, [{0, id, _}]} = read.(ctx.user.id)
      assert id == ctx.note.id
      assert read.(other.id) == {:returned, []}
    end
  end
end
