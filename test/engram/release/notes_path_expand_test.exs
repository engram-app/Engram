defmodule Engram.Release.NotesPathExpandTest do
  @moduledoc """
  Release L's owner-run boot steps (`Engram.Release.NotesPathExpand`, run
  through `Engram.Release.BootStep` by `Engram.Release.migrate/0`): relax
  `notes_kind_shape_v4_check`, build the name collision guard
  `notes_name_live` and the manifest's name covering index
  `notes_manifest_name`. None may fail boot: a held lock, a duplicate or a
  failed build defers, the ledger stays open and the next boot retries; an
  INVALID index is never done, it is dropped and rebuilt.

  The steps run outside the sandbox (CONCURRENTLY cannot run in a
  transaction), so each test puts release K's shape back, committed, and
  on exit runs the steps to completion, so the shared test DB ends as
  release L leaves it.
  """
  use Engram.DataCase, async: false

  import Engram.ServiceFlagsHelpers, only: [use_source: 1]
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Release
  alias Engram.Release.{BootStep, NotesPathExpand}
  alias Engram.Repo

  @names ~w(notes_shape_relax notes_name_unique_build notes_manifest_name_build)

  @shape_v4 """
  ALTER TABLE notes ADD CONSTRAINT notes_kind_shape_v4_check CHECK (
    (kind = 'note'   AND path_hmac IS NOT NULL AND title_ciphertext IS NOT NULL
                     AND tags_ciphertext IS NOT NULL)
    OR
    (kind = 'folder' AND path_hmac IS NULL AND title_ciphertext IS NULL
                     AND tags_ciphertext IS NULL AND folder_hmac IS NOT NULL))
  """

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp reset! do
    unboxed(fn ->
      Repo.query!("DROP INDEX IF EXISTS notes_name_live")
      Repo.query!("DROP INDEX IF EXISTS notes_manifest_name")
      Repo.query!("ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_v5_check")
      Repo.query!("ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_v4_check")
      Repo.query!(@shape_v4)
      Repo.query!("DELETE FROM data_migrations WHERE name = ANY($1)", [@names])
    end)

    Engram.DataMigrations.reset_cache()
  end

  defp finish!(owners) do
    delete_owners!(Enum.map(owners, &Ecto.UUID.dump!/1))
    unboxed(fn -> Repo.query!("DELETE FROM data_migrations WHERE name = ANY($1)", [@names]) end)

    Engram.DataMigrations.reset_cache()
    assert Enum.all?(run(), fn {_, r} -> r == :done end)
  end

  setup do
    reset!()
    {:ok, agent} = Agent.start(fn -> [] end)
    Process.put(:owners_agent, agent)

    on_exit(fn ->
      owners = Agent.get(agent, & &1)
      Agent.stop(agent)
      finish!(owners)
    end)

    :ok
  end

  defp owners, do: Process.get(:owners_agent)

  defp run(opts \\ []),
    do: unboxed(fn -> BootStep.run_all(Repo, NotesPathExpand.steps(opts), opts) end)

  defp run_one(name, opts \\ []) do
    {^name, result} = List.keyfind(run(opts), name, 0)
    result
  end

  defp constraints do
    unboxed(fn ->
      Repo.query!("""
      SELECT conname, convalidated FROM pg_constraint
      WHERE conrelid = 'public.notes'::regclass AND conname LIKE 'notes_kind_shape%'
      ORDER BY conname
      """).rows
    end)
  end

  defp index(name), do: unboxed(fn -> BootStep.index_state(Repo, name) end)

  defp ledger(name) do
    unboxed(fn ->
      case Repo.query!("SELECT completed_at IS NOT NULL FROM data_migrations WHERE name = $1", [
             name
           ]).rows do
        [] -> nil
        [[done]] -> done
      end
    end)
  end

  # A committed owner (the steps' sessions see only committed rows), deleted
  # with everything it owns on exit.
  defp committed_owner! do
    {:ok, user} = unboxed(fn -> Engram.Crypto.ensure_user_dek(insert(:user)) end)
    vault = unboxed(fn -> insert(:vault, user: user) end)
    Agent.update(owners(), &[user.id | &1])
    {user, vault}
  end

  defp committed_note!(user, vault, path) do
    {:ok, note} =
      unboxed(fn ->
        Engram.Notes.upsert_note(user, vault, %{"path" => path, "content" => "x"}, actor: "api")
      end)

    note
  end

  # Makes `b` a second live note at `a`'s folder row and exact name.
  defp same_name!(a, b) do
    unboxed(fn ->
      Repo.query!(
        "UPDATE notes b SET name_hmac = a.name_hmac, folder_ref_id = a.folder_ref_id " <>
          "FROM notes a WHERE a.id = $1 AND b.id = $2",
        [Ecto.UUID.dump!(a.id), Ecto.UUID.dump!(b.id)]
      )
    end)
  end

  defp delete_owners!(ids) do
    unboxed(fn ->
      for t <- ~w(notes folders vaults),
          do: Repo.query!("DELETE FROM #{t} WHERE user_id = ANY($1)", [ids])

      Repo.query!("DELETE FROM users WHERE id = ANY($1)", [ids])
    end)
  end

  defp hold_notes_lock! do
    {:ok, conn} =
      Repo.config()
      |> Keyword.drop([:pool, :pool_size, :parameters])
      |> Postgrex.start_link()

    Postgrex.query!(conn, "BEGIN", [])
    Postgrex.query!(conn, "LOCK TABLE notes IN ACCESS EXCLUSIVE MODE", [])
    conn
  end

  defp release!(conn) do
    Postgrex.query!(conn, "ROLLBACK", [])
    GenServer.stop(conn)
  end

  defp flags_file!(doc) do
    path = Path.join(System.tmp_dir!(), "rel_l_flags_#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(doc))
    on_exit(fn -> File.rm(path) end)
    use_source({:file, path})
  end

  test "the release runs one step list: K's drop, then L's three, in order" do
    assert Enum.map(Release.boot_steps(), & &1.name) == ["folder_path_hash_drop" | @names]
  end

  describe "notes_shape_relax" do
    test "relaxes the check: a live note may lack path_hmac, a tombstone may not" do
      assert run_one("notes_shape_relax") == :done
      assert constraints() == [["notes_kind_shape_v5_check", true]]
      assert ledger("notes_shape_relax") == true

      {user, vault} = committed_owner!()
      note = committed_note!(user, vault, "A/x.md")
      id = Ecto.UUID.dump!(note.id)

      unboxed(fn ->
        Repo.query!("UPDATE notes SET path_hmac = NULL WHERE id = $1", [id])

        assert_raise Postgrex.Error, ~r/notes_kind_shape_v5_check/, fn ->
          Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [id])
        end
      end)
    end

    test "a held lock defers it, nothing changes; released, the next run completes" do
      conn = hold_notes_lock!()
      log = capture_log(fn -> assert run_one("notes_shape_relax") == :deferred end)
      assert log =~ "notes_shape_relax deferred"
      assert ledger("notes_shape_relax") == false
      release!(conn)

      assert ["notes_kind_shape_v4_check", true] in constraints()
      assert run_one("notes_shape_relax") == :done
      assert constraints() == [["notes_kind_shape_v5_check", true]]
    end

    # A boot killed between the NOT VALID add and the VALIDATE: the rerun
    # validates it and drops v4, never adds it twice.
    test "rerun-safe from a half-done state (v5 NOT VALID beside v4)" do
      unboxed(fn ->
        Repo.query!(
          "ALTER TABLE notes ADD CONSTRAINT notes_kind_shape_v5_check " <>
            "CHECK (kind IN ('note', 'folder')) NOT VALID"
        )
      end)

      assert run_one("notes_shape_relax") == :done
      assert constraints() == [["notes_kind_shape_v5_check", true]]
    end
  end

  describe "notes_name_unique_build" do
    setup do
      {user, vault} = committed_owner!()
      a = committed_note!(user, vault, "A/x.md")
      b = committed_note!(user, vault, "A/y.md")
      %{user: user, vault: vault, a: a, b: b}
    end

    defp dup!(ctx), do: same_name!(ctx.a, ctx.b)

    test "builds a valid unique index that refuses a second live note at a name", ctx do
      assert run_one("notes_name_unique_build") == :done
      assert index("notes_name_live") == :valid

      assert_raise Postgrex.Error, ~r/notes_name_live/, fn -> dup!(ctx) end
    end

    # Case-sensitive like today's path guard: `X.md` beside `x.md` is fine.
    # Live-only: a tombstone at the same name is not a duplicate.
    test "another case, or a tombstone at the name, is not a duplicate", ctx do
      committed_note!(ctx.user, ctx.vault, "A/X.md")
      dup!(ctx)

      unboxed(fn ->
        Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [
          Ecto.UUID.dump!(ctx.b.id)
        ])
      end)

      assert run_one("notes_name_unique_build") == :done
      assert index("notes_name_live") == :valid
    end

    test "the probe finds a duplicate: deferred and logged, no index", ctx do
      dup!(ctx)
      log = capture_log(fn -> assert run_one("notes_name_unique_build") == :deferred end)

      assert log =~ "notes_name_unique_build deferred"
      assert log =~ "duplicates=1"
      assert index("notes_name_live") == :absent
      assert ledger("notes_name_unique_build") == false
    end

    # Under FORCE RLS the migrator may see no rows, so the probe is blind and
    # the build's own unique check finds the duplicate. Its INVALID leftover
    # would still refuse writes, so it is dropped at once.
    test "a duplicate the probe missed: the failed build defers and leaves no index", ctx do
      dup!(ctx)

      log =
        capture_log(fn ->
          assert run_one("notes_name_unique_build", probe: false) == :deferred
        end)

      assert log =~ "duplicates_found_by_build"
      assert index("notes_name_live") == :absent
    end

    test "the duplicate removed, the next run builds it", ctx do
      dup!(ctx)
      capture_log(fn -> assert run_one("notes_name_unique_build") == :deferred end)

      unboxed(fn ->
        Repo.query!("DELETE FROM notes WHERE id = $1", [Ecto.UUID.dump!(ctx.b.id)])
      end)

      assert run_one("notes_name_unique_build") == :done
      assert index("notes_name_live") == :valid
    end
  end

  describe "INVALID indexes (a build killed with its task)" do
    # A real killed build: CONCURRENTLY commits the catalog entry, then waits
    # out an older snapshot; the build is cancelled there, as a SIGKILLed
    # task's would be, and the index is left INVALID.
    defp killed_build!(sql) do
      {:ok, holder} =
        Repo.config() |> Keyword.drop([:pool, :pool_size, :parameters]) |> Postgrex.start_link()

      {:ok, builder} =
        Repo.config() |> Keyword.drop([:pool, :pool_size, :parameters]) |> Postgrex.start_link()

      Postgrex.query!(holder, "BEGIN ISOLATION LEVEL REPEATABLE READ", [])
      Postgrex.query!(holder, "SELECT count(*) FROM notes", [])
      %{rows: [[pid]]} = Postgrex.query!(builder, "SELECT pg_backend_pid()", [])

      task = Task.async(fn -> Postgrex.query(builder, sql, [], timeout: 30_000) end)

      wait_until(fn ->
        %{rows: rows} =
          Postgrex.query!(
            holder,
            "SELECT 1 FROM pg_stat_activity WHERE pid = $1 AND wait_event_type = 'Lock'",
            [pid]
          )

        rows != []
      end)

      # The kill: the build's backend cancelled mid-wait.
      Postgrex.query!(holder, "SELECT pg_cancel_backend($1)", [pid])

      assert {:error, %Postgrex.Error{postgres: %{code: :query_canceled}}} = Task.await(task)
      Postgrex.query!(holder, "ROLLBACK", [])
      GenServer.stop(holder)
      GenServer.stop(builder)
    end

    defp wait_until(fun, tries \\ 100) do
      cond do
        fun.() -> :ok
        tries == 0 -> flunk("timed out")
        true -> Process.sleep(50) && wait_until(fun, tries - 1)
      end
    end

    test "the unique index left INVALID is dropped and rebuilt, never marked done as is" do
      killed_build!(
        "CREATE UNIQUE INDEX CONCURRENTLY notes_name_live ON notes (vault_id, folder_ref_id, name_hmac) " <>
          "WHERE deleted_at IS NULL AND kind = 'note'"
      )

      assert index("notes_name_live") == :invalid
      assert run_one("notes_name_unique_build") == :done
      assert index("notes_name_live") == :valid
    end

    test "the manifest index left INVALID is dropped and rebuilt" do
      killed_build!("CREATE INDEX CONCURRENTLY notes_manifest_name ON notes (user_id)")

      assert index("notes_manifest_name") == :invalid
      assert run_one("notes_manifest_name_build") == :done
      assert index("notes_manifest_name") == :valid

      # Rebuilt with the real definition, not kept from the killed one.
      %{rows: [[defn]]} =
        unboxed(fn -> Repo.query!("SELECT pg_get_indexdef('notes_manifest_name'::regclass)") end)

      assert defn =~ "INCLUDE (dek_version, seq, content_hash, folder_ref_id, name_ciphertext"
    end
  end

  describe "kill switches" do
    # The test config logs warnings and up; these assert info lines.
    setup do
      level = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: level) end)
    end

    test "each flag stops only its own step, and every pending step logs its read" do
      flags_file!(%{"notes_name_unique_build" => false})

      log = capture_log([level: :info], fn -> run() end)

      assert ledger("notes_name_unique_build") == nil
      assert index("notes_name_live") == :absent
      assert ledger("notes_shape_relax") == true
      assert ledger("notes_manifest_name_build") == true

      assert log =~ "notes_name_unique_build flags read source=file value=false"
      assert log =~ "notes_shape_relax flags read source=file value=absent"
      assert log =~ "notes_manifest_name_build flags read source=file value=absent"
    end

    test "no source (self-host): every step reads none and runs" do
      log = capture_log([level: :info], fn -> run() end)

      for name <- @names do
        assert log =~ "#{name} flags read source=none value=absent"
        assert ledger(name) == true
      end
    end

    test "the flags-read line is a :boot info line, which ships to Loki" do
      log =
        capture_log(
          [level: :info, format: "$metadata$message\n", metadata: [:category, :loki_ship]],
          fn ->
            run()
          end
        )

      assert log =~ ~r/category=boot loki_ship=true notes_shape_relax flags read source=none/
    end

    test "a done step reads no flags and logs nothing" do
      assert Enum.all?(run(), fn {_, r} -> r == :done end)

      log =
        capture_log([level: :info], fn -> assert Enum.all?(run(), &(elem(&1, 1) == :skipped)) end)

      refute log =~ "flags read"
    end
  end
end
