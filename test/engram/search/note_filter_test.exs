defmodule Engram.Search.NoteFilterTest do
  @moduledoc """
  The Postgres filter resolver (R10.2) and filter-only search (R10.3): every
  note filter answered in Postgres as `{:ids, _} | {:exclude, _} | :too_wide`.
  Not async: the plan tests rewrite `notes` / `note_attrs` with CLUSTER
  (`QueryPlan` `fresh: true`), and the RLS tests drop the role.
  """
  use Engram.DataCase, async: false

  import Engram.FieldCatalogHelpers
  import Engram.RlsCase

  alias Engram.Notes
  alias Engram.QueryPlan
  alias Engram.Search.NoteFilter

  setup do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp note!(ctx, path, fm \\ nil) do
    content = if fm, do: "---\n#{fm}\n---\nbody\n", else: "body\n"
    write_indexed!(ctx.user, ctx.vault, path, content)
  end

  defp resolve(ctx, filter, opts \\ []) do
    {:ok, out} = NoteFilter.resolve(ctx.user, ctx.vault, filter, opts)
    sorted(out)
  end

  defp sorted({tag, ids}) when is_list(ids), do: {tag, Enum.sort(ids)}
  defp sorted(other), do: other

  defp ids(notes), do: notes |> Enum.map(& &1.id) |> Enum.sort()

  # Prod and staging finished the `note_split` ledger: lookups use the
  # 16-byte key columns and their indexes.
  defp note_split_done! do
    :ok = Engram.DataMigrations.mark_done("note_split", 1)
    Engram.Cache.clear_local(:note_split)

    on_exit(fn ->
      Engram.Cache.clear_local(:note_split)
      Engram.DataMigrations.reset_cache()
    end)
  end

  defp set_note!(ctx, note, set) do
    Engram.Repo.with_tenant!(ctx.user.id, fn ->
      Engram.Repo.update_all(
        from(n in Engram.Notes.Note, where: n.id == ^note.id and n.kind == "note"),
        set: set
      )
    end)
  end

  describe "contract" do
    test "empty vault: nothing matches, whatever the filter", ctx do
      assert resolve(ctx, %{}) == {:ids, []}
      assert resolve(ctx, %{tags: ["x"]}) == {:ids, []}
    end

    test "empty filter matches every live note", ctx do
      a = note!(ctx, "a.md")
      b = note!(ctx, "b.md")
      assert resolve(ctx, %{}) == {:ids, ids([a, b])}
      refute NoteFilter.any?(%{tags: [], folder: nil})
      assert NoteFilter.any?(tags: ["x"])
    end

    test "exactly cap matches is :ids; cap + 1 flips to the complement", ctx do
      [a, b, c] = for p <- ~w(a b c), do: note!(ctx, "#{p}.md", "tags: [t]")
      d = note!(ctx, "d.md")

      assert resolve(ctx, %{tags: ["t"]}, cap: 3) == {:ids, ids([a, b, c])}
      assert resolve(ctx, %{tags: ["t"]}, cap: 2) == {:exclude, [d.id]}
    end

    test "both sides over the cap is :too_wide", ctx do
      for p <- ~w(a b), do: note!(ctx, "#{p}.md", "tags: [t]")
      for p <- ~w(c d), do: note!(ctx, "#{p}.md")

      assert resolve(ctx, %{tags: ["t"]}, cap: 1) == :too_wide

      assert resolve(ctx, %{tags: ["t"]}, cap: 2) ==
               {:ids, resolve(ctx, %{tags: ["t"]}) |> elem(1)}
    end

    test "every note matching is {:exclude, []}", ctx do
      for p <- ~w(a b), do: note!(ctx, "#{p}.md", "tags: [t]")
      assert resolve(ctx, %{tags: ["t"]}, cap: 1) == {:exclude, []}
    end

    test "a trashed note is in neither list", ctx do
      a = note!(ctx, "a.md", "tags: [t]")
      a2 = note!(ctx, "a2.md", "tags: [t]")
      gone = note!(ctx, "gone.md", "tags: [t]")
      b = note!(ctx, "b.md")
      :ok = Notes.delete_note(ctx.user, ctx.vault, "gone.md")

      assert resolve(ctx, %{tags: ["t"]}) == {:ids, ids([a, a2])}
      assert resolve(ctx, %{tags: ["t"]}, cap: 1) == {:exclude, [b.id]}
      refute gone.id in elem(resolve(ctx, %{}), 1)
    end

    test "another user's and another vault's notes are never returned", ctx do
      mine = note!(ctx, "a.md", "tags: [t]")

      {:ok, other} = Engram.Crypto.ensure_user_dek(insert(:user))
      other_vault = insert(:vault, user: other)
      write_indexed!(other, other_vault, "a.md", "---\ntags: [t]\n---\nx\n")
      my_other_vault = insert(:vault, user: ctx.user)
      write_indexed!(ctx.user, my_other_vault, "b.md", "---\ntags: [t]\n---\nx\n")

      assert resolve(ctx, %{tags: ["t"]}) == {:ids, [mine.id]}
      assert resolve(ctx, %{}) == {:ids, [mine.id]}
      assert resolve(ctx, %{not: %{tags: ["t"]}}) == {:ids, []}
      assert resolve(ctx, %{tags: ["t"]}, cap: 0) == {:exclude, []}
    end
  end

  describe "filters" do
    test "tags: any of, nested prefix included, never a sibling prefix", ctx do
      api = note!(ctx, "api.md", "tags: [proj/engram/api]")
      proj = note!(ctx, "proj.md", "tags: [proj]")
      _sib = note!(ctx, "sib.md", "tags: [proj/engramx]")
      other = note!(ctx, "other.md", "tags: [other]")

      assert resolve(ctx, %{tags: ["proj/engram"]}) == {:ids, [api.id]}
      assert resolve(ctx, %{tags: ["#proj/engram"]}) == {:ids, [api.id]}
      {:ids, all_proj} = resolve(ctx, %{tags: ["proj"]})
      assert api.id in all_proj and proj.id in all_proj and length(all_proj) == 3
      assert resolve(ctx, %{tags: ["other", "proj/engram"]}) == {:ids, ids([api, other])}
    end

    # Obsidian matches tags case-insensitively, nested ones included.
    test "tags: case folded, nested included", ctx do
      x = note!(ctx, "x.md", "tags: [project/x]")
      p = note!(ctx, "p.md", "tags: [project]")
      _o = note!(ctx, "o.md", "tags: [other]")

      assert resolve(ctx, %{tags: ["Project"]}) == {:ids, ids([x, p])}
      assert resolve(ctx, %{tags: ["PROJECT/X"]}) == {:ids, [x.id]}
    end

    test "folder: the folder and its whole subtree, nothing beside it", ctx do
      x = note!(ctx, "A/x.md")
      y = note!(ctx, "A/B/y.md")
      _ab = note!(ctx, "AB/z.md")
      _root = note!(ctx, "r.md")

      assert resolve(ctx, %{folder: "A"}) == {:ids, ids([x, y])}
      assert resolve(ctx, %{folder: "A/"}) == {:ids, ids([x, y])}
      assert resolve(ctx, %{folder: "A/B"}) == {:ids, [y.id]}
      assert resolve(ctx, %{folder: "missing"}) == {:ids, []}
      assert {:ids, all} = resolve(ctx, %{folder: ""})
      assert length(all) == 4
    end

    # A note the previous release wrote before its folder had a row (until
    # `DataMigrations.FolderTable` heals it) still carries the folder's key.
    for split <- [false, true] do
      test "folder: a note whose folder has no row yet (ids: #{split})", ctx do
        if unquote(split), do: note_split_done!()
        x = note!(ctx, "A/x.md")
        _other = note!(ctx, "B/y.md")

        Engram.Repo.with_tenant!(ctx.user.id, fn ->
          Engram.Repo.delete_all(
            from(f in Engram.Folders.Folder, where: f.vault_id == ^ctx.vault.id)
          )
        end)

        assert resolve(ctx, %{folder: "A"}) == {:ids, [x.id]}
      end
    end

    test "type and typed frontmatter fields read note_attrs", ctx do
      a = note!(ctx, "a.md", "type: Playbook\nstatus: draft\npriority: 3\nmood: calm")
      b = note!(ctx, "b.md", "type: Reference\npriority: 1\nmood: tense")

      assert resolve(ctx, %{type: "playbook"}) == {:ids, [a.id]}
      assert resolve(ctx, %{fields: [%{"key" => "status", "value" => "draft"}]}) == {:ids, [a.id]}
      # `stable` is the default: it matches a note with no status.
      assert resolve(ctx, %{fields: [%{"key" => "status", "value" => "stable"}]}) ==
               {:ids, [b.id]}

      assert resolve(ctx, %{fields: [%{"key" => "priority", "op" => "gt", "value" => 1}]}) ==
               {:ids, [a.id]}

      assert resolve(ctx, %{fields: [%{"key" => "mood", "op" => "in", "value" => ["tense"]}]}) ==
               {:ids, [b.id]}
    end

    test "an unknown field is an error, never an empty result", ctx do
      note!(ctx, "a.md")

      assert NoteFilter.resolve(ctx.user, ctx.vault, %{fields: [%{"key" => "nope", "value" => 1}]}) ==
               {:error, {:unknown_field, "nope"}}
    end

    test "dates: frontmatter first, then the file time, inclusive bounds", ctx do
      old = note!(ctx, "old.md", "created: 2020-01-01\nupdated: 2020-06-01")
      new = note!(ctx, "new.md", "created: 2026-01-01")
      # No frontmatter date: `write_indexed!` sets mtime 1.0 (1970) and no ctime.
      bare = note!(ctx, "bare.md")

      assert resolve(ctx, %{created_after: ~U[2025-01-01 00:00:00Z]}) ==
               {:ids, ids([new, bare])}

      assert resolve(ctx, %{created_before: ~U[2020-01-01 00:00:00Z]}) == {:ids, [old.id]}
      # `new` has no `updated` either: both fall back to mtime 1.0.
      assert resolve(ctx, %{updated_before: ~U[2000-01-01 00:00:00Z]}) == {:ids, ids([new, bare])}

      assert resolve(ctx, %{
               updated_after: ~U[2020-06-01 00:00:00Z],
               updated_before: ~U[2021-01-01 00:00:00Z]
             }) ==
               {:ids, [old.id]}

      assert resolve(ctx, %{
               fields: [%{"key" => "created", "op" => "before", "value" => "2021-01-01"}]
             }) ==
               {:ids, [old.id]}
    end

    # A range reads the stored effective date (`notes.eff_updated`, derived
    # by the save) and falls back to the row time when it is NULL.
    test "dates read notes.eff_updated, else the row time", ctx do
      old = note!(ctx, "old.md", "updated: 2020-06-01")
      bare = note!(ctx, "bare.md")
      range = %{updated_after: ~U[2020-01-01 00:00:00Z], updated_before: ~U[2021-01-01 00:00:00Z]}

      assert resolve(ctx, range) == {:ids, [old.id]}

      # The column alone moves `bare` into the range.
      set_note!(ctx, bare, eff_updated: DateTime.to_unix(~U[2020-03-01 00:00:00Z]))
      assert resolve(ctx, range) == {:ids, ids([old, bare])}

      # NULL: the row time (now).
      set_note!(ctx, old, eff_updated: nil)
      assert resolve(ctx, range) == {:ids, [bare.id]}
      assert resolve(ctx, %{updated_after: ~U[2026-01-01 00:00:00Z]}) == {:ids, [old.id]}
    end

    # The plugin's ctime sweep fills ctime on existing notes; a note with no
    # created date then filters by it, one with one keeps its own.
    test "the ctime fill moves a note's created date, not a frontmatter one", ctx do
      bare = note!(ctx, "bare.md")
      fm = note!(ctx, "fm.md", "created: 2020-01-01")
      ctime = DateTime.to_unix(~U[2010-06-01 00:00:00Z]) * 1.0

      {:ok, 2} =
        Notes.set_client_ctimes(ctx.user, ctx.vault, [
          %{path: "bare.md", ctime: ctime},
          %{path: "fm.md", ctime: ctime}
        ])

      year = %{created_after: ~U[2010-01-01 00:00:00Z], created_before: ~U[2011-01-01 00:00:00Z]}
      assert resolve(ctx, year) == {:ids, [bare.id]}
      assert resolve(ctx, %{created_before: ~U[2020-01-02 00:00:00Z]}) == {:ids, ids([bare, fm])}
    end

    # Obsidian writes a datetime property with no seconds and no offset:
    # the filter reads it as the payload does, not the file time.
    test "created: an Obsidian datetime is the frontmatter's date", ctx do
      n = note!(ctx, "o.md", "created: 2024-01-01T10:00")
      day = %{created_after: ~U[2024-01-01 00:00:00Z], created_before: ~U[2024-01-02 00:00:00Z]}
      assert resolve(ctx, day) == {:ids, [n.id]}
    end

    # A date-only field holds a day: a bound inside that day matches it, in
    # Postgres as in Qdrant (day numbers, the operator kept).
    test "a date-only field compares days, whatever the bound's time", ctx do
      n = note!(ctx, "d.md", "due: 2026-11-05")

      at = fn op ->
        %{fields: [%{"key" => "due", "op" => op, "value" => "2026-11-05T12:00:00Z"}]}
      end

      assert resolve(ctx, at.("gte")) == {:ids, [n.id]}
      assert resolve(ctx, at.("lte")) == {:ids, [n.id]}
      assert resolve(ctx, at.("lt")) == {:ids, []}
      assert resolve(ctx, at.("gt")) == {:ids, []}
    end

    test "and / or / not combine", ctx do
      a = note!(ctx, "a.md", "tags: [x]\nstatus: draft")
      b = note!(ctx, "b.md", "tags: [y]")
      c = note!(ctx, "c.md", "tags: [x, y]")

      assert resolve(ctx, %{or: [%{tags: ["x"]}, %{tags: ["y"]}]}) == {:ids, ids([a, b, c])}
      assert resolve(ctx, %{and: [%{tags: ["x"]}, %{tags: ["y"]}]}) == {:ids, [c.id]}
      assert resolve(ctx, %{tags: ["x"], not: %{tags: ["y"]}}) == {:ids, [a.id]}

      assert resolve(ctx, %{not: %{fields: [%{"key" => "status", "value" => "draft"}]}}) ==
               {:ids, ids([b, c])}

      assert resolve(ctx, %{or: []}) == {:ids, []}
      assert resolve(ctx, %{and: []}) == {:ids, ids([a, b, c])}
    end

    # `folder_ref_id` is NULL for a root note: `NOT (folder IN ...)` must
    # still match it, not drop it as NULL.
    test "not over a NULL column keeps the note", ctx do
      note!(ctx, "A/x.md")
      note!(ctx, "A/y.md")
      r = note!(ctx, "r.md")
      assert resolve(ctx, %{not: %{folder: "A"}}) == {:ids, [r.id]}
      assert resolve(ctx, %{folder: "A"}, cap: 1) == {:exclude, [r.id]}
    end
  end

  describe "within: and cross-vault" do
    test "within returns the intersection with the filter", ctx do
      a = note!(ctx, "a.md", "tags: [t]")
      b = note!(ctx, "b.md", "tags: [t]")
      c = note!(ctx, "c.md")

      assert resolve(ctx, %{tags: ["t"]}, within: [a.id, c.id]) == {:ids, [a.id]}
      assert resolve(ctx, %{}, within: [b.id, c.id]) == {:ids, ids([b, c])}
      assert resolve(ctx, %{tags: ["t"]}, within: []) == {:ids, []}
    end

    test "within never returns another user's or another vault's ids", ctx do
      mine = note!(ctx, "a.md", "tags: [t]")
      {:ok, other} = Engram.Crypto.ensure_user_dek(insert(:user))
      theirs = write_indexed!(other, insert(:vault, user: other), "a.md", "---\ntags: [t]\n---\n")

      elsewhere =
        write_indexed!(ctx.user, insert(:vault, user: ctx.user), "b.md", "---\ntags: [t]\n---\n")

      assert resolve(ctx, %{tags: ["t"]}, within: [mine.id, theirs.id, elsewhere.id]) ==
               {:ids, [mine.id]}
    end

    test "cross-vault: the cap is on the union; over it is :too_wide, never :exclude", ctx do
      v2 = insert(:vault, user: ctx.user)
      a = note!(ctx, "a.md", "tags: [t]")
      b = write_indexed!(ctx.user, v2, "b.md", "---\ntags: [t]\n---\n")
      write_indexed!(ctx.user, v2, "c.md", "body\n")

      run = fn opts ->
        {:ok, out} = NoteFilter.resolve(ctx.user, [ctx.vault, v2], %{tags: ["t"]}, opts)
        sorted(out)
      end

      assert run.(cap: 2) == {:ids, ids([a, b])}
      assert run.(cap: 1) == :too_wide
      assert run.(cap: 1, within: [a.id, b.id]) == {:ids, ids([a, b])}
    end

    test "sample: a :too_wide answer carries {matched, sampled}, bounded by the sample", ctx do
      tagged = for i <- 1..3, do: note!(ctx, "t#{i}.md", "tags: [t]")
      for i <- 1..3, do: note!(ctx, "u#{i}.md")
      gone = hd(tagged)
      note!(ctx, "u4.md")
      set_note!(ctx, gone, deleted_at: DateTime.utc_now())

      # 2 tagged + 4 untagged live notes; the sample reads at most 4 of them.
      assert {:too_wide, {matched, 4}} = resolve(ctx, %{tags: ["t"]}, cap: 1, sample: 4)
      assert matched in 0..2
      assert resolve(ctx, %{tags: ["t"]}, cap: 1, sample: 100) == {:too_wide, {2, 6}}
      # No `sample:`: the plain contract.
      assert resolve(ctx, %{tags: ["t"]}, cap: 1) == :too_wide
      # A narrow answer carries no sample.
      assert resolve(ctx, %{tags: ["t"]}, sample: 4) == {:ids, ids(tl(tagged))}
    end
  end

  describe "page/4 (filter-only search)" do
    test "newest first, keyset cursor, filter applied", ctx do
      notes =
        for p <- ~w(a b c) do
          n = note!(ctx, "#{p}.md", "tags: [t]")
          Process.sleep(2)
          n
        end

      note!(ctx, "skip.md")

      assert {:ok, %{notes: [c, b], next_cursor: cursor}} =
               NoteFilter.page(ctx.user, ctx.vault, %{tags: ["t"]}, limit: 2)

      assert {c.path, b.path} == {"c.md", "b.md"}

      assert {:ok, %{notes: [a], next_cursor: nil}} =
               NoteFilter.page(ctx.user, ctx.vault, %{tags: ["t"]}, limit: 2, cursor: cursor)

      assert a.id == hd(notes).id
    end

    # A selective filter pages over its ids, never the newest-first walk
    # with the filter per row (the whole vault for a rare match); a dense
    # one walks. Same notes either way.
    test "a selective filter pages over its ids; a dense one walks", ctx do
      rare = note!(ctx, "r.md", "tags: [rare]")
      for p <- ~w(a b c), do: note!(ctx, "#{p}.md", "tags: [t]")

      page = fn filter, page_ids ->
        {{:ok, %{notes: notes}}, queries} =
          Engram.QueryRecorder.record(fn ->
            NoteFilter.page(ctx.user, ctx.vault, filter, limit: 5, page_ids: page_ids)
          end)

        me = self()
        [sql] = for %{pid: ^me, sql: sql} <- queries, sql =~ "ORDER BY", do: sql
        {Enum.map(notes, & &1.id), sql}
      end

      {[id], sql} = page.(%{tags: ["rare"]}, 2)
      assert id == rare.id
      assert sql =~ ~r/n0\."id" = ANY\(/, sql
      refute sql =~ "note_attrs", sql

      {ids, sql} = page.(%{tags: ["t"]}, 2)
      assert length(ids) == 3
      assert sql =~ "note_attrs", sql
    end

    test "a cursor from another vault is refused", ctx do
      for p <- ~w(a b), do: note!(ctx, "#{p}.md")
      {:ok, %{next_cursor: cursor}} = NoteFilter.page(ctx.user, ctx.vault, %{}, limit: 1)
      other = insert(:vault, user: ctx.user)

      assert NoteFilter.page(ctx.user, other, %{}, cursor: cursor) == {:error, :invalid_cursor}
    end
  end

  describe "tenant isolation under the app role" do
    test "control: the dropped role with no tenant sees no notes", ctx do
      note!(ctx, "a.md")

      # Raw SQL: the app's tenant guard would raise before RLS is reached.
      assert {:returned, %{rows: [[0]]}} =
               as_prod_role(fn -> Engram.Repo.query!("SELECT count(*)::int FROM notes") end)
    end

    test "resolve sets the tenant itself, folder walk and tag list included", ctx do
      a = note!(ctx, "A/a.md", "tags: [t/x]")
      note!(ctx, "b.md", "tags: [t/x]")

      assert {:returned, {:ok, {:ids, [id]}}} =
               as_prod_role(fn ->
                 NoteFilter.resolve(ctx.user, ctx.vault, %{folder: "A", tags: ["t"]})
               end)

      assert id == a.id

      assert {:returned, {:ok, %{notes: [%{id: ^id}]}}} =
               as_prod_role(fn -> NoteFilter.page(ctx.user, ctx.vault, %{folder: "A"}) end)
    end
  end

  describe "plans (EXPLAIN on the statements resolve/4 sends)" do
    # The plan of `sql` on an all-visible `notes` (as vacuumed prod), where
    # a covering index is costed as the index-only scan it is.
    defp index_only_plan(sql),
      do:
        QueryPlan.generic_plan(sql,
          analyze: ~w(notes),
          fresh: true,
          bitmapscan: false,
          all_visible: true
        )

    # Every `notes` statement resolve/4 sends (the match query, then the
    # complement when the match is over the cap).
    defp statements(ctx, filter, opts) do
      {_, queries} =
        Engram.QueryRecorder.record(fn ->
          NoteFilter.resolve(ctx.user, ctx.vault, filter, opts)
        end)

      me = self()

      for %{pid: ^me, sql: sql} <- queries,
          sql =~ ~r/^SELECT n0."id" FROM "notes"/,
          do: sql
    end

    defp statement(ctx, filter) do
      {_, queries} =
        Engram.QueryRecorder.record(fn -> NoteFilter.resolve(ctx.user, ctx.vault, filter) end)

      me = self()

      %{sql: sql} =
        queries |> Enum.filter(&(&1.pid == me and &1.sql =~ ~r/FROM "notes"/)) |> List.last()

      sql
    end

    # 40 notes in one vault; `n_distinct = 40` makes the planner see 40
    # tenants, as prod sees hundreds, so `vault_id = $n` is selective
    # (`notes_generic_plan_test.exs`). The ALTERs roll back with the sandbox.
    # A vault index served the generic plan of a 40-row table whatever the
    # filter, with `n_distinct` telling it one row per vault: the date and
    # folder plans are asked on a table that is all one vault instead, with
    # the filtered column spread out, so only the filter column can narrow it.
    defp seed_spread!(ctx) do
      for i <- 1..40 do
        note!(ctx, "F#{i}/n#{i}.md", "tags: [t]")
      end

      Engram.Repo.query!(
        "UPDATE notes SET eff_updated = 1000000 * (abs(hashtext(id::text)) % 1000), " <>
          "eff_created = 1000000 * (abs(hashtext(id::text)) % 997) WHERE vault_id = $1",
        [Ecto.UUID.dump!(ctx.vault.id)]
      )
    end

    defp seed_plan!(ctx) do
      for i <- 1..40 do
        note!(
          ctx,
          "F#{rem(i, 4)}/n#{i}.md",
          "tags: [t#{rem(i, 5)}]\nstatus: s#{rem(i, 3)}\npriority: #{i}"
        )
      end

      for t <- ~w(notes note_attrs),
          c <- ~w(user_id vault_id),
          do: Engram.Repo.query!("ALTER TABLE #{t} ALTER COLUMN #{c} SET (n_distinct = 40)")
    end

    test "field filters read note_attrs by its vault index, notes by a vault index", ctx do
      seed_plan!(ctx)

      for fields <- [
            [%{"key" => "priority", "op" => "gte", "value" => 5}],
            [%{"key" => "status", "value" => "s1"}],
            [
              %{"key" => "status", "value" => "s1"},
              %{"key" => "priority", "op" => "lt", "value" => 9}
            ]
          ] do
        sql = statement(ctx, %{fields: fields})
        # `h = ANY($n)` is costed as 10 descents; on 40 rows one bitmap over
        # the pkey then wins. The question is whether the vault index CAN serve it.
        plan =
          QueryPlan.generic_plan(sql,
            analyze: ~w(notes note_attrs),
            fresh: true,
            bitmapscan: false
          )

        assert plan =~ ~r/note_attrs_vault_id_key_id_[hn]_index/, plan
        refute plan =~ ~r/Seq Scan on (notes|note_attrs)/, plan
      end
    end

    # Staging 2026-11-05: `notes.tags_hmac && $n` read every live note's
    # heap (~7 ms per 1k notes); the note_attrs h index reads the matches.
    test "a tag filter reads the note_attrs h index, never a seq scan", ctx do
      seed_plan!(ctx)

      plan =
        QueryPlan.generic_plan(statement(ctx, %{tags: ["t1"]}),
          analyze: ~w(notes note_attrs),
          fresh: true,
          bitmapscan: false
        )

      assert plan =~ "note_attrs_vault_id_key_id_h_index", plan
      refute plan =~ ~r/Seq Scan on notes/, plan
    end

    # Staging 2026-11-05: `folder_ref_id = ANY OR folder_id = ANY` (in a
    # coalesce) read the heap of every live note, and so did its complement.
    # Both are index-only scans of notes_folder_live.
    test "a folder filter and its complement are index-only on notes_folder_live", ctx do
      seed_spread!(ctx)
      note_split_done!()

      # cap 0: the match query AND the complement query run.
      for sql <- statements(ctx, %{folder: "F7"}, cap: 0) do
        plan = index_only_plan(sql)
        assert plan =~ "Index Only Scan using notes_folder_live", plan
      end
    end

    # Staging 2026-11-05: pulled up into a join, the attr subquery was
    # costed from a default estimate and probed notes_pkey once per match
    # (15 to 24 us each, 150 to 250 ms at the cap on 40k notes). It must be a
    # hashed SubPlan with the notes side index-only, never notes_pkey.
    test "tag and field filters are a hashed subplan over an index-only live scan", ctx do
      seed_spread!(ctx)

      for filter <- [
            %{tags: ["t"]},
            %{fields: [%{"key" => "tags", "value" => "t"}]},
            %{tags: ["t"], fields: [%{"key" => "tags", "op" => "in", "value" => ["t", "u"]}]}
          ],
          sql <- statements(ctx, filter, cap: 0) do
        plan = index_only_plan(sql)
        assert plan =~ "hashed SubPlan", plan
        assert plan =~ ~r/Index Only Scan using \w+ on notes/, plan
        refute plan =~ "notes_pkey", plan
      end
    end

    test "a date range and its complement are index-only on notes_eff_*_live", ctx do
      seed_spread!(ctx)

      for sql <- statements(ctx, %{updated_after: ~U[2000-01-01 00:00:00Z]}, cap: 0) do
        plan = index_only_plan(sql)
        assert plan =~ "Index Only Scan using notes_eff_updated_live", plan
      end
    end

    test "after + before on one date is one range, no note_attrs read", ctx do
      note!(ctx, "a.md")

      sql =
        statement(ctx, %{
          updated_after: ~U[2025-01-01 00:00:00Z],
          updated_before: ~U[2026-01-01 00:00:00Z]
        })

      refute sql =~ "note_attrs", sql
      assert length(Regex.scan(~r/COALESCE\(n0\."eff_updated"/, sql)) == 2, sql
    end

    test "a date range reads notes_eff_updated_live / notes_eff_created_live", ctx do
      seed_spread!(ctx)

      for {filter, index} <- [
            {%{updated_after: ~U[2025-01-01 00:00:00Z]}, "notes_eff_updated_live"},
            {%{created_before: ~U[2025-01-01 00:00:00Z]}, "notes_eff_created_live"}
          ] do
        plan =
          QueryPlan.generic_plan(statement(ctx, filter),
            analyze: ~w(notes note_attrs),
            fresh: true
          )

        assert plan =~ index, plan
        refute plan =~ "notes_user_vault_live", plan
      end
    end

    test "status: stable reads the h index for its missing-status half", ctx do
      seed_plan!(ctx)
      sql = statement(ctx, %{fields: [%{"key" => "status", "value" => "stable"}]})
      plan = QueryPlan.generic_plan(sql, analyze: ~w(notes note_attrs), fresh: true)
      refute plan =~ "note_attrs_pkey", plan
    end
  end
end
