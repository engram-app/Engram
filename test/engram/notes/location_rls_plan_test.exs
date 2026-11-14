defmodule Engram.Notes.LocationRlsPlanTest do
  # The S3 reads (Engram#2523) planned as prod runs them: as `engram_app`
  # with the tenant set, so FORCE RLS applies, in a custom AND a forced
  # generic plan (`QueryPlan.rls_plans/3`). Staging 2026-11-13: the by-path
  # lookup's `path_id = $ OR <name key>` qual applied `byteacat` and
  # `uuid_send` to columns, neither leakproof, so under RLS no part of it
  # could drive an index and every lookup read the tenant's whole vault on
  # `notes_user_vault_live` (1,341 buffers on 1,530 notes against 4 on
  # 0.83.0). `LocationPlanTest` reads plans as the suite's superuser, which
  # skips RLS, so it never saw it. See
  # docs/context/rls-leakproof-index-quals.md.
  #
  # Each test records the statements the real call sends and plans every
  # one that reads `notes` or `folders`: none may scan a vault's notes
  # (`notes_user_vault_live`, a Seq Scan), and the by-path lookup in a vault
  # with no moved folder reads `notes_path_live` within 0.83.0's buffers.
  #
  # 1,000 seeded notes, with `n_distinct = 40` on the tenant columns so a
  # generic `vault_id = $n` is costed as prod's (notes_generic_plan_mis_pick).
  # Not async: ALTER TABLE and the role drop.
  use Engram.DataCase, async: false

  alias Engram.{Crypto, DataMigrations, Notes}
  alias Engram.QueryPlan
  alias Engram.QueryRecorder
  alias Engram.Repo

  setup do
    on_exit(fn ->
      Engram.Cache.clear_local(:note_split)
      DataMigrations.reset_cache()
    end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    Engram.Fixtures.insert_notes!(
      user,
      vault,
      for(
        _ <- 1..1000,
        do:
          build(:note,
            path_hmac: :crypto.strong_rand_bytes(32),
            folder_hmac: :crypto.strong_rand_bytes(32),
            basename_hmac: :crypto.strong_rand_bytes(32)
          )
      )
    )

    # The real notes after the seeded ones, so a feed page from `after`
    # reads only notes that decrypt.
    %{rows: [[after_seq]]} =
      Repo.query!("SELECT max(seq) FROM notes WHERE vault_id = $1", [Ecto.UUID.dump!(vault.id)])

    for path <- ["A/B/x.md", "A/B/y.md", "top.md"] do
      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => path, "content" => "# #{path}\n\nbody"},
          actor: "api"
        )
    end

    # Siblings at every level, so a probe by parent alone reads many rows
    # and the planner weighs the name (as LocationPlanTest does).
    {:ok, _} =
      Engram.Folders.create_markers(
        user,
        vault,
        for(i <- 1..60, do: "R#{i}") ++ for(i <- 1..60, do: "A/S#{i}")
      )

    leave_dead_name_keys!(vault)

    Repo.query!("ALTER TABLE notes ALTER COLUMN user_id SET (n_distinct = 40)")
    Repo.query!("ALTER TABLE notes ALTER COLUMN vault_id SET (n_distinct = 40)")
    # Rewritten, then ANALYZEd: the plan sees this test's rows only, not
    # the dead entries above or any earlier test's (`QueryPlan.fresh!/1`).
    QueryPlan.fresh!("notes")
    QueryPlan.fresh!("folders")

    :ok = DataMigrations.mark_done("note_split", 1)
    Engram.Cache.clear_local(:note_split)
    assert Notes.Keys.ids?()
    assert Notes.Location.on?()

    %{user: user, vault: vault, after_seq: after_seq}
  end

  # The physical state earlier tests in a CI partition leave behind: keyed
  # rows written and rolled back, whose dead entries stay in
  # `notes_name_key_live` (the sandbox rollback does not undo them). With a
  # handful of live keyed rows on many index pages, the planner costs that
  # index above `notes_user_vault_live`, both `user_id` and the probe's
  # `name_key` being InitPlan params it cannot estimate, and the name arm
  # read the whole vault (CI seed 805596, 1,124 rows removed by filter).
  defp leave_dead_name_keys!(vault) do
    Repo.transaction(fn ->
      for _ <- 1..50,
          do:
            Repo.query!(
              "UPDATE notes SET name_key = sha512(gen_random_uuid()::text::bytea) " <>
                "WHERE vault_id = $1 AND name_key IS NULL",
              [Ecto.UUID.dump!(vault.id)]
            )

      Repo.rollback(:dead_keys)
    end)
  end

  # The vault holds a folder renamed without a cascade (an empty marker, so
  # no note's chain changes): the S5 write shape.
  defp mark_moved!(user, vault) do
    {:ok, _} = Engram.Folders.create_markers(user, vault, ["Moved"])

    Repo.query!(
      "UPDATE folders SET notes_cascaded = false WHERE vault_id = $1 AND parent_id IS NULL",
      [Ecto.UUID.dump!(vault.id)]
    )
  end

  # `%{sql => plans}` for every read of `notes` or `folders` `fun` sends,
  # after running it 7 times on this connection (past the 5 custom plans
  # Postgres tries before it may switch a named statement to a generic
  # one). `plans.custom` is always read; `plans.generic` only for a
  # statement Postgrex prepared NAMED, the only kind that can go generic: a
  # keyed `notes` lookup runs unnamed (`Keys.lookup?/1`), so its generic
  # plan is never run (0.83.0's own path lookup reads the whole vault on a
  # forced generic plan here, which is why it is unnamed;
  # notes-generic-plan-mis-pick.md). That it stays unnamed is asserted too.
  defp plans(user, fun) do
    Repo.query!("DISCARD PLANS")
    {_, queries} = QueryRecorder.record(fn -> for _ <- 1..7, do: fun.() end)
    me = self()

    reads =
      for %{sql: sql, params: params, pid: ^me} <- queries,
          sql =~ ~r/^\s*(WITH|SELECT)/i,
          sql =~ ~r/FROM "?(notes|folders)"?/,
          into: %{},
          do: {sql, params}

    assert reads != %{}, "no read of notes or folders recorded"

    %{rows: named} =
      Repo.query!("SELECT statement FROM pg_prepared_statements WHERE statement = ANY($1)", [
        Map.keys(reads)
      ])

    named = MapSet.new(List.flatten(named))

    Map.new(reads, fn {sql, params} ->
      plans = QueryPlan.rls_plans(user.id, sql, params)
      plans = if MapSet.member?(named, sql), do: plans, else: Map.delete(plans, :generic)
      {sql, plans}
    end)
  end

  @bad ["notes_user_vault_live", "Seq Scan on notes", "Seq Scan on folders", "folders_parent"]

  # Every custom plan; the generic plan of a statement S3 added or changed
  # (each carries the moved-folder probe on `notes_cascaded`: the by-path
  # name arm, a chain read, the feed's moved column). A named statement S3
  # left alone keeps 0.83.0's plan.
  defp refute_vault_scan!(plans) do
    for {sql, by_mode} <- plans,
        {mode, plan} <- by_mode,
        mode == :custom or sql =~ "notes_cascaded",
        bad <- @bad,
        do: refute(plan =~ bad, "#{mode} plan reads #{bad}:\n#{sql}\n\n#{plan}")
  end

  defp lookup_plans(plans) do
    for {sql, p} <- plans, sql =~ ~s("path_id" = $), do: p
  end

  # 0.83.0's lookup reads the live path index once: 4 buffers on staging.
  @lookup_buffers 6

  describe "by-path lookup" do
    test "no moved folder: notes_path_live in 0.83.0's buffers, never generic", ctx do
      plans =
        plans(ctx.user, fn -> assert Notes.note_exists?(ctx.user, ctx.vault, "A/B/x.md") end)

      refute_vault_scan!(plans)

      # Unnamed, so never generic (a generic plan would read the vault).
      assert [%{custom: custom} = lookup] = lookup_plans(plans)
      refute Map.has_key?(lookup, :generic)
      assert custom =~ "notes_path_live", custom
      assert QueryPlan.buffers(custom) <= @lookup_buffers, custom

      # 0.83.0's statement: no walk, no name probe, no moved-folder probe
      # inside it (each costs planning on every unnamed call).
      refute custom =~ "folders", custom

      # The moved-folder probe is its own statement: one read of
      # `folders_moved_live` in the custom and the generic plan.
      assert [probe] = for({sql, p} <- plans, sql =~ "notes_cascaded", do: p)

      for mode <- [:custom, :generic] do
        assert probe[mode] =~ "folders_moved_live", probe[mode]
        assert QueryPlan.buffers(probe[mode]) <= 2, probe[mode]
      end
    end

    test "a moved folder: name key and walk on their indexes, no vault scan", ctx do
      mark_moved!(ctx.user, ctx.vault)

      # An unheld path, so the walk and the name probe both run.
      plans =
        plans(ctx.user, fn -> refute Notes.note_exists?(ctx.user, ctx.vault, "A/B/new.md") end)

      refute_vault_scan!(plans)

      assert [%{custom: custom}] = lookup_plans(plans)

      for index <- [
            "notes_path_live",
            "folders_moved_live",
            "folders_live_name",
            "notes_name_key_live"
          ],
          do: assert(custom =~ index, "expected #{index}:\n#{custom}")

      # The moved arm adds the walk (one probe per segment, two here), the
      # holder probe and one name probe: measured 14-15 buffers, flat in the
      # vault's size.
      assert QueryPlan.buffers(custom) <= @lookup_buffers + 12, custom
    end
  end

  # The other S3 reads that add a statement or a column (the feed page's
  # moved column, the chain reads of search, get-by-id and list_folder, and
  # get_notes), in both vault states.
  for moved? <- [false, true] do
    describe "S3 reads, moved folder #{moved?}" do
      setup ctx do
        if unquote(moved?), do: mark_moved!(ctx.user, ctx.vault)
        :ok
      end

      test "get_notes", ctx do
        refute_vault_scan!(
          plans(ctx.user, fn ->
            Notes.get_notes_within(ctx.user, ctx.vault, ["A/B/x.md", "top.md"], 10_000_000)
          end)
        )
      end

      test "feed page", ctx do
        refute_vault_scan!(
          plans(ctx.user, fn ->
            {:ok, _} = Notes.list_changes_by_seq(ctx.user, ctx.vault, ctx.after_seq)
          end)
        )
      end

      test "get_note_by_id", ctx do
        {:ok, %{id: id}} = Notes.get_note(ctx.user, ctx.vault, "A/B/x.md")

        refute_vault_scan!(
          plans(ctx.user, fn -> {:ok, _} = Notes.get_note_by_id(ctx.user, ctx.vault, id) end)
        )
      end

      test "list_folder", ctx do
        refute_vault_scan!(
          plans(ctx.user, fn -> Notes.list_notes_in_folder_page(ctx.user, ctx.vault, "A/B") end)
        )
      end
    end
  end
end
