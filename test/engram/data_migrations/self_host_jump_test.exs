defmodule Engram.DataMigrations.SelfHostJumpTest do
  @moduledoc """
  A self-hoster jumping from a release before `note_bodies` straight to
  R8(c), on one node: every note is pre-split (only the `notes` columns, no
  body row). The upgrade's migrations run before boot, and migration
  20261107120000 gives every note its body row, byte for byte what the app
  writes, so every note reads before any data migration runs. Then writes
  land before the ledgers reach them; run every registered data migration
  until NoteSplit and NoteBodyColumnsNull are done: every note reads its
  latest content throughout, and both `notes` ciphertext columns end NULL.
  """
  use Engram.DataCase, async: false

  alias Engram.Backfill.IdWindows
  alias Engram.DataMigrations
  alias Engram.DataMigrations.{NoteBodyColumnsNull, NoteSplit}
  alias Engram.Notes
  alias Engram.Notes.CrdtCheckpoint
  alias Engram.Workers.DataMigrationsRunner

  setup do
    IdWindows.reset_walks()
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Jump", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp write!(u, v, path, content) do
    {:ok, n} = Notes.upsert_note(u, v, %{"path" => path, "content" => content}, actor: "api")
    n
  end

  defp doc_with(text) do
    doc = Yex.Doc.new()
    Yex.Text.insert(Yex.Doc.get_text(doc, "content"), 0, text)
    doc
  end

  defp read!(u, v, path) do
    assert {:ok, %{content: content}} = Notes.get_note(u, v, path)
    content
  end

  # What a release before `note_bodies` leaves: the `notes` copies, no body.
  defp pre_split!(u) do
    ids =
      Repo.query!("SELECT id FROM notes WHERE user_id = $1 AND kind = 'note'", [
        Ecto.UUID.dump!(u.id)
      ]).rows
      |> Enum.map(fn [id] -> Ecto.UUID.load!(id) end)

    Enum.each(ids, &Engram.Fixtures.old_release_notes_copy!/1)
    Repo.query!("DELETE FROM note_bodies WHERE user_id = $1", [Ecto.UUID.dump!(u.id)])
  end

  defp copies(u) do
    Repo.query!(
      """
      SELECT count(*) FILTER (WHERE content_ciphertext IS NOT NULL OR crdt_state_ciphertext IS NOT NULL)
      FROM notes WHERE user_id = $1 AND kind = 'note'
      """,
      [Ecto.UUID.dump!(u.id)]
    ).rows
  end

  defp bodies(u) do
    Repo.query!(
      """
      SELECT note_id, user_id, key_version, content_ct, crdt_ct, crdt_head,
        content_bytes, state_bytes, envelope_legacy
      FROM note_bodies WHERE user_id = $1 ORDER BY note_id
      """,
      [Ecto.UUID.dump!(u.id)]
    ).rows
  end

  defp run_all do
    for mod <- DataMigrationsRunner.migrations(), do: DataMigrationsRunner.run(mod)
    :ok
  end

  defp both_done? do
    DataMigrations.done?(NoteSplit.name(), NoteSplit.version()) and
      DataMigrations.done?(NoteBodyColumnsNull.name(), NoteBodyColumnsNull.version())
  end

  test "pre-split notes plus release-B writes: every ledger closes, reads stay right, no copies",
       %{user: u, vault: v} do
    edited = write!(u, v, "edited.md", "old text")
    checkpointed = write!(u, v, "board.md", "board text")
    _ = write!(u, v, "plain.md", "plain text")
    _ = write!(u, v, "moved.md", "moved text")
    {:ok, _} = Notes.rename_note(u, v, "moved.md", "Dir/moved.md")
    pre_split!(u)
    # The upgrade's migrations, before boot.
    Engram.Fixtures.complete_split!()

    expected = %{
      "edited.md" => "old text",
      "board.md" => "board text",
      "plain.md" => "plain text",
      "Dir/moved.md" => "moved text"
    }

    for {path, text} <- expected, do: assert(read!(u, v, path) == text)

    # Release-B writes before the ledgers run: an edit and a checkpoint.
    write!(u, v, "edited.md", "new text")
    :ok = CrdtCheckpoint.checkpoint(u.id, v.id, checkpointed.id, doc_with("checkpointed"))
    expected = %{expected | "edited.md" => "new text"}
    assert read!(u, v, "board.md") =~ "checkpointed"
    assert read!(u, v, "edited.md") == "new text"
    _ = edited

    Enum.reduce_while(1..8, nil, fn _, _ ->
      run_all()
      if both_done?(), do: {:halt, :ok}, else: {:cont, nil}
    end)

    assert both_done?(), "NoteSplit and NoteBodyColumnsNull must both reach :done"
    assert copies(u) == [[0]]

    for {path, text} <- Map.delete(expected, "board.md"), do: assert(read!(u, v, path) == text)
    assert read!(u, v, "board.md") =~ "checkpointed"
  end

  test "a pre-split database booted on this release: every note has its body row, byte for byte, and reads before any data migration runs",
       %{user: u, vault: v} do
    checkpointed = write!(u, v, "board.md", "board text")
    :ok = CrdtCheckpoint.checkpoint(u.id, v.id, checkpointed.id, doc_with("checkpointed"))
    _ = write!(u, v, "plain.md", "plain text")
    _ = write!(u, v, "moved.md", "moved text")
    {:ok, _} = Notes.rename_note(u, v, "moved.md", "Dir/moved.md")
    written = bodies(u)
    assert length(written) >= 3
    assert Enum.any?(written, fn row -> Enum.at(row, 4) != nil end), "one CRDT state"

    pre_split!(u)
    assert bodies(u) == []

    Engram.Fixtures.complete_split!()

    assert bodies(u) == written
    refute DataMigrations.done?(NoteSplit.name(), NoteSplit.version())
    assert read!(u, v, "plain.md") == "plain text"
    assert read!(u, v, "Dir/moved.md") == "moved text"
    assert read!(u, v, "board.md") =~ "checkpointed"

    # Rerun-safe: a second run (a retried boot) writes nothing.
    Engram.Fixtures.complete_split!()
    assert bodies(u) == written
  end

  # Under the RLS-enforced runtime role (`engram_app`, not the owner, no
  # bypass), as prod's non-superuser migrator sees the tables: the per-user
  # tenant context must see and insert every row. The suite's own role
  # bypasses RLS, so without this CI never runs the policy path.
  test "under the RLS-enforced role, the split inserts every body row", %{user: u, vault: v} do
    _ = write!(u, v, "rls.md", "rls text")
    written = bodies(u)
    pre_split!(u)

    Engram.Fixtures.complete_split!(role: "engram_app")

    assert bodies(u) == written
    assert read!(u, v, "rls.md") == "rls text"
  end

  # The one note the insert skips: its body row exists but is owned by
  # another user (drift; hand-edited SQL or a restore), so the tenant policy
  # hides it, ON CONFLICT keeps it, and every read (which joins on the
  # owner) gets a NULL body. Nothing else can heal it, so the migration
  # repairs it, and only then bypasses RLS.
  defp foreign_body!(note) do
    Repo.query!("UPDATE note_bodies SET user_id = $2 WHERE note_id = $1", [
      Ecto.UUID.dump!(note.id),
      Ecto.UUID.dump!(insert(:user).id)
    ])
  end

  test "a body row owned by another user, body NULL, notes copy present: rebuilt from the copy",
       %{user: u, vault: v} do
    note = write!(u, v, "owned.md", "owned text")
    Engram.Fixtures.old_release_notes_copy!(note.id)

    Repo.query!("UPDATE note_bodies SET content_ct = NULL WHERE note_id = $1", [
      Ecto.UUID.dump!(note.id)
    ])

    foreign_body!(note)
    assert read!(u, v, "owned.md") == nil

    Engram.Fixtures.complete_split!()
    assert read!(u, v, "owned.md") == "owned text"
  end

  # #2545 review MED-1: a pre-nonce note (notes nonce NULL, the envelope
  # merged into the notes ciphertext) under a foreign body row with a NULL
  # body. The walk's insert copies such a row as it is, so the repair must
  # too; it once left the body NULL and counted the note done.
  test "a body row owned by another user, body NULL, pre-nonce notes copy: rebuilt from the copy",
       %{user: u, vault: v} do
    note = write!(u, v, "owned.md", "owned text")
    Engram.Fixtures.pre_nonce_null_body!(note.id)
    foreign_body!(note)
    assert read!(u, v, "owned.md") == nil

    Engram.Fixtures.complete_split!()
    assert read!(u, v, "owned.md") == "owned text"
  end

  # Strictly non-destructive: SQL cannot tell a stale notes copy from a
  # stale body, so existing body bytes are never overwritten. A body that
  # does not match the notes nonce is handed back as it is, with a warning
  # for a human look.
  test "a body row owned by another user, body not matching the nonce: kept, warned",
       %{user: u, vault: v} do
    import ExUnit.CaptureLog
    note = write!(u, v, "owned.md", "owned text")
    Engram.Fixtures.old_release_notes_copy!(note.id)
    odd = <<1>> <> :crypto.strong_rand_bytes(60)

    Repo.query!("UPDATE note_bodies SET content_ct = $2 WHERE note_id = $1", [
      Ecto.UUID.dump!(note.id),
      odd
    ])

    foreign_body!(note)

    log = capture_log([level: :warning], fn -> assert :ok = Engram.Fixtures.complete_split!() end)
    assert log =~ "does not match"
    assert log =~ note.id

    %{rows: [[ct, owner]]} =
      Repo.query!("SELECT content_ct, user_id FROM note_bodies WHERE note_id = $1", [
        Ecto.UUID.dump!(note.id)
      ])

    assert ct == odd
    assert Ecto.UUID.load!(owner) == u.id
  end

  test "a body row owned by another user, no notes copy: handed back to the owner",
       %{user: u, vault: v} do
    import ExUnit.CaptureLog
    note = write!(u, v, "owned.md", "owned text")
    foreign_body!(note)
    assert read!(u, v, "owned.md") == nil

    log = capture_log([level: :warning], fn -> assert :ok = Engram.Fixtures.complete_split!() end)
    assert log =~ "handed back to their owner (content: body"
    assert read!(u, v, "owned.md") == "owned text"
  end

  # Review HIGH-1: release B writes only the nonce on `notes`, so an edited
  # note keeps an OLD notes ciphertext under its NEW nonce, while the body
  # holds the new envelope. The repair must keep the body (its prefix
  # matches the notes nonce), not rebuild it from the stale copy.
  test "a body row owned by another user after a release-B edit keeps the newer body",
       %{user: u, vault: v} do
    note = write!(u, v, "edited.md", "first text")
    Engram.Fixtures.old_release_notes_copy!(note.id)
    write!(u, v, "edited.md", "second text")
    foreign_body!(note)
    assert read!(u, v, "edited.md") == nil

    Engram.Fixtures.complete_split!()
    assert read!(u, v, "edited.md") == "second text"
  end

  # Prod's migrator owns the tables but is no superuser, so FORCE RLS binds
  # it and the foreign body row is invisible: only the repair's NO FORCE
  # lets it reach the row. The suite's role bypasses RLS, so this runs the
  # split as a NOSUPERUSER NOBYPASSRLS role that owns `note_bodies` (DDL in
  # the sandbox, rolled back). Without the NO FORCE / FORCE pair the UPDATE
  # is filtered, not rejected (RLS trap 1), and the note still reads nil.
  test "the owner repair reaches the row as a non-superuser owner of note_bodies",
       %{user: u, vault: v} do
    note = write!(u, v, "owned.md", "owned text")
    foreign_body!(note)

    Repo.query!("CREATE ROLE r8c_migrator NOSUPERUSER NOBYPASSRLS NOINHERIT")

    Repo.query!(
      "GRANT SELECT, INSERT, UPDATE ON users, notes, note_bodies, note_index_state TO r8c_migrator"
    )

    Repo.query!("ALTER TABLE note_bodies OWNER TO r8c_migrator")

    log =
      ExUnit.CaptureLog.capture_log([level: :warning], fn ->
        assert :ok = Engram.Fixtures.complete_split!(role: "r8c_migrator")
      end)

    refute log =~ "still read with no body"
    assert read!(u, v, "owned.md") == "owned text"
  end

  # A repo with no `checkout`: the walk over every user once ran inside one,
  # which inherited DBConnection's 15s and crashed boot at prod's user count.
  defmodule NoCheckoutRepo do
    @moduledoc false
    defdelegate query!(sql), to: Engram.Repo
    defdelegate query!(sql, params), to: Engram.Repo
    defdelegate query!(sql, params, opts), to: Engram.Repo
    defdelegate transaction(fun), to: Engram.Repo
    defdelegate transaction(fun, opts), to: Engram.Repo
  end

  # Fails the body insert with a lock timeout: forever for the user in
  # `:always`, or the first `:times` calls for anyone. `:persistent_term`, as
  # a migration runs in its own process.
  defmodule FlakyRepo do
    @moduledoc false
    @key {__MODULE__, :plan}

    def plan(plan) do
      :persistent_term.put(@key, :counters.new(1, []))
      :persistent_term.put({__MODULE__, :spec}, plan)
    end

    defdelegate query!(sql), to: Engram.Repo
    defdelegate query!(sql, params, opts), to: Engram.Repo
    defdelegate transaction(fun), to: Engram.Repo
    defdelegate transaction(fun, opts), to: Engram.Repo

    def query!(sql, [user_id | _] = params) do
      if String.contains?(sql, "INSERT INTO note_bodies") and fail?(user_id) do
        raise %Postgrex.Error{
          postgres: %{
            code: :lock_not_available,
            pg_code: "55P03",
            severity: "ERROR",
            message: "lock timeout"
          }
        }
      end

      Engram.Repo.query!(sql, params)
    end

    def query!(sql, params), do: Engram.Repo.query!(sql, params)

    defp fail?(user_id) do
      counter = :persistent_term.get(@key)
      spec = :persistent_term.get({__MODULE__, :spec})
      :counters.add(counter, 1, 1)

      user_id == spec[:always] or :counters.get(counter, 1) <= Keyword.get(spec, :times, 0)
    end
  end

  # The real runner, so "not recorded" is what Ecto does with the raise.
  defmodule FlakyMigration do
    @moduledoc false
    use Ecto.Migration
    @disable_ddl_transaction true
    @disable_migration_lock true

    def up do
      mod =
        String.to_existing_atom("Elixir.Engram.Repo.Migrations.NoteBodiesCompleteSplitMigrate")

      mod.complete_split(FlakyRepo)
    end
  end

  # Raises what DBConnection raises when a transaction outlives its checkout
  # deadline (#2545 review MED-2): for a body insert window wider than
  # `:max` notes, or one holding note `:never`. A window with no size
  # parameter is the old fixed 1,000.
  defmodule SlowRepo do
    @moduledoc false
    @key {__MODULE__, :spec}

    def plan(spec), do: :persistent_term.put(@key, spec)

    defdelegate query!(sql), to: Engram.Repo
    defdelegate query!(sql, params, opts), to: Engram.Repo
    defdelegate transaction(fun), to: Engram.Repo
    defdelegate transaction(fun, opts), to: Engram.Repo

    def query!(sql, [user_id, after_id | rest] = params) do
      if String.contains?(sql, "INSERT INTO note_bodies") and
           too_slow?(user_id, after_id, List.first(rest, 1_000)) do
        raise DBConnection.ConnectionError,
              "client timed out because it checked out the connection"
      end

      Engram.Repo.query!(sql, params)
    end

    def query!(sql, params), do: Engram.Repo.query!(sql, params)

    defp too_slow?(user_id, after_id, size) do
      spec = :persistent_term.get(@key)

      ids =
        Engram.Repo.query!(
          "SELECT id FROM notes WHERE user_id = $1 AND id > $2 ORDER BY id LIMIT $3",
          [user_id, after_id, size]
        ).rows

      size > Keyword.get(spec, :max, 1_000) or [spec[:never]] in ids
    end
  end

  # Records every statement, and refuses the per-user probe with a lock
  # timeout the first `:times` calls (#2545 review LOW-3).
  defmodule ProbeLockedRepo do
    @moduledoc false
    @key {__MODULE__, :left}

    def plan(times) do
      :persistent_term.put(@key, :counters.new(1, []))
      :counters.put(:persistent_term.get(@key), 1, times)
      :persistent_term.put({__MODULE__, :log}, :ets.new(__MODULE__, [:public, :duplicate_bag]))
    end

    def log, do: :persistent_term.get({__MODULE__, :log}) |> :ets.tab2list() |> Enum.sort()

    defdelegate transaction(fun), to: Engram.Repo
    defdelegate transaction(fun, opts), to: Engram.Repo

    def query!(sql), do: query!(sql, [], [])
    def query!(sql, params), do: query!(sql, params, [])

    def query!(sql, params, opts) do
      :ets.insert(
        :persistent_term.get({__MODULE__, :log}),
        {System.unique_integer([:monotonic]), sql}
      )

      left = :persistent_term.get(@key)

      if String.starts_with?(String.trim(sql), "SELECT EXISTS") and
           String.contains?(sql, "n.user_id = $1") and :counters.get(left, 1) > 0 do
        :counters.sub(left, 1, 1)

        raise %Postgrex.Error{
          postgres: %{
            code: :lock_not_available,
            pg_code: "55P03",
            severity: "ERROR",
            message: "lock timeout"
          }
        }
      end

      Engram.Repo.query!(sql, params, opts)
    end
  end

  describe "the pre-check and the walk" do
    # What the pre-check would be with no thought for RLS.
    @blind_exists """
    SELECT EXISTS (
      SELECT 1 FROM notes n
      WHERE n.kind = 'note'
        AND NOT EXISTS (SELECT 1 FROM note_bodies x
                        WHERE x.note_id = n.id AND x.user_id = n.user_id))
    """
    @migrator "r8c_migrator"
    @statement_bound 8

    # Prod's shape: owns `note_bodies`, no superuser, no BYPASSRLS, so FORCE
    # RLS binds it. `maintenance?` adds what lets it see every tenant.
    defp migrator!(maintenance?) do
      Repo.query!("CREATE ROLE #{@migrator} NOSUPERUSER NOBYPASSRLS NOINHERIT")

      Repo.query!(
        "GRANT SELECT, INSERT, UPDATE ON users, notes, note_bodies, note_index_state TO #{@migrator}"
      )

      Repo.query!("ALTER TABLE note_bodies OWNER TO #{@migrator}")

      if maintenance? do
        Repo.query!("GRANT engram_maintenance TO #{@migrator} WITH INHERIT FALSE, SET TRUE")
      end
    end

    # The tenant is cleared first: one set by an earlier write in this sandbox
    # transaction would leak forward and make the role see rows.
    defp as_migrator(fun) do
      Repo.query!("SELECT set_config('app.current_tenant', '', true)")
      Repo.query!("SET LOCAL SESSION AUTHORIZATION #{@migrator}")

      try do
        fun.()
      after
        Repo.query!("SET LOCAL SESSION AUTHORIZATION DEFAULT")
      end
    end

    defp statements(fun) do
      test_pid = self()
      handler = "count-statements-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:engram, :repo, :query],
        fn _event, _measure, _meta, _cfg ->
          if self() == test_pid, do: Process.put(:statements, Process.get(:statements, 0) + 1)
        end,
        nil
      )

      Process.put(:statements, 0)
      fun.()
      :telemetry.detach(handler)
      Process.get(:statements)
    end

    defp grows?(opts) do
      few = statements(fn -> Engram.Fixtures.complete_split!(opts) end)
      for _ <- 1..2_000, do: insert(:user)
      many = statements(fn -> Engram.Fixtures.complete_split!(opts) end)
      {few, many}
    end

    test "nothing to split, as a role that sees every row: bounded statements", %{
      user: u,
      vault: v
    } do
      _ = write!(u, v, "kept.md", "kept text")

      {few, many} = grows?([])

      assert many == few
      assert many <= @statement_bound
    end

    test "nothing to split, as a maintenance member under RLS: bounded statements", %{
      user: u,
      vault: v
    } do
      _ = write!(u, v, "kept.md", "kept text")
      migrator!(true)

      {few, many} = grows?(role: @migrator)

      assert many == few
      assert many <= @statement_bound
    end

    test "no connection is held across the walk", %{user: u, vault: v} do
      _ = write!(u, v, "held.md", "held text")
      written = bodies(u)
      pre_split!(u)

      Engram.Fixtures.complete_split!(repo: NoCheckoutRepo)

      assert bodies(u) == written
    end

    test "as a role that cannot see every tenant, nothing to split costs 2 statements a user",
         %{user: u, vault: v} do
      _ = write!(u, v, "kept.md", "kept text")
      migrator!(false)
      users = 300

      few = statements(fn -> Engram.Fixtures.complete_split!(role: @migrator) end)
      for _ <- 1..users, do: insert(:user)
      many = statements(fn -> Engram.Fixtures.complete_split!(role: @migrator) end)

      assert many - few <= 2 * users + 8
    end

    test "a window that hits a lock timeout is retried", %{user: u, vault: v} do
      _ = write!(u, v, "retry.md", "retry text")
      written = bodies(u)
      pre_split!(u)
      FlakyRepo.plan(times: 2)

      Engram.Fixtures.complete_split!(repo: FlakyRepo)

      assert bodies(u) == written
    end

    test "a window too slow for its deadline is halved and retried", %{user: u, vault: v} do
      for i <- 1..5, do: write!(u, v, "slow#{i}.md", "slow text #{i}")
      written = bodies(u)
      pre_split!(u)
      SlowRepo.plan(max: 2)

      assert :ok = Engram.Fixtures.complete_split!(repo: SlowRepo)

      assert bodies(u) == written
    end

    test "a note too slow even alone is logged and left, the rest done, boot not blocked", %{
      user: u,
      vault: v
    } do
      import ExUnit.CaptureLog
      for i <- 1..3, do: write!(u, v, "ok#{i}.md", "ok text #{i}")
      stuck = write!(u, v, "stuck.md", "stuck text")
      pre_split!(u)
      SlowRepo.plan(never: Ecto.UUID.dump!(stuck.id))

      log =
        capture_log([level: :warning], fn ->
          assert :ok = Engram.Fixtures.complete_split!(repo: SlowRepo)
        end)

      assert log =~ "too slow"
      assert log =~ stuck.id
      for i <- 1..3, do: assert(read!(u, v, "ok#{i}.md") == "ok text #{i}")
      assert read!(u, v, "stuck.md") == nil
    end

    test "the per-user probe sets a lock timeout and retries a batch that hits it", %{
      user: u,
      vault: v
    } do
      _ = write!(u, v, "probe.md", "probe text")
      written = bodies(u)
      pre_split!(u)
      ProbeLockedRepo.plan(1)

      assert :ok = Engram.Fixtures.complete_split!(repo: ProbeLockedRepo)
      assert bodies(u) == written

      sqls = Enum.map(ProbeLockedRepo.log(), &elem(&1, 1))
      first_probe = Enum.find_index(sqls, &(&1 =~ "SELECT EXISTS" and &1 =~ "n.user_id = $1"))
      assert Enum.any?(Enum.take(sqls, first_probe), &(&1 =~ "lock_timeout"))
    end

    test "a probe batch that keeps hitting its lock timeout is walked anyway", %{
      user: u,
      vault: v
    } do
      _ = write!(u, v, "probe.md", "probe text")
      written = bodies(u)
      pre_split!(u)
      ProbeLockedRepo.plan(100)

      assert :ok = Engram.Fixtures.complete_split!(repo: ProbeLockedRepo)
      assert bodies(u) == written
    end

    test "a user that keeps failing: others done, count raised, migration not recorded", %{
      user: u,
      vault: v
    } do
      _ = write!(u, v, "stuck.md", "stuck text")
      pre_split!(u)

      {:ok, other} = Engram.Crypto.ensure_user_dek(insert(:user))
      insert(:user_limit_override, user: other, key: "vaults_cap", value: %{"v" => -1})
      {:ok, other_vault, _} = Engram.Vaults.register_vault(other, "Other", Ecto.UUID.generate())
      _ = write!(other, other_vault, "done.md", "done text")
      written = bodies(other)
      pre_split!(other)

      Engram.Fixtures.complete_split!(role: nil, only_load: true)
      FlakyRepo.plan(always: Ecto.UUID.dump!(u.id))
      version = 99_999_999_999_991

      error =
        assert_raise RuntimeError, fn ->
          Ecto.Migrator.up(Repo, version, FlakyMigration, log: false)
        end

      assert error.message =~ "1 user"
      refute error.message =~ u.id
      assert bodies(other) == written
      assert bodies(u) == []

      assert Repo.query!("SELECT count(*) FROM schema_migrations WHERE version = $1", [version]).rows ==
               [[0]]
    end

    test "the walk logs progress on a Loki-shipped boot line, with no user ids", %{
      user: u,
      vault: v
    } do
      _ = write!(u, v, "log.md", "log text")
      pre_split!(u)
      for _ <- 1..250, do: insert(:user)
      Engram.Fixtures.complete_split!(role: nil, only_load: true)

      mod =
        String.to_existing_atom("Elixir.Engram.Repo.Migrations.NoteBodiesCompleteSplitMigrate")

      Logger.put_module_level(mod, :info)
      on_exit(fn -> Logger.delete_module_level(mod) end)
      migrator!(false)

      {_, events} =
        Engram.Test.LogCapture.with_events(fn ->
          Engram.Fixtures.complete_split!(role: @migrator)
        end)

      lines =
        for %{meta: %{category: :boot} = meta, msg: {:string, text}} <- events do
          assert meta.loki_ship == true
          IO.chardata_to_string(text)
        end

      assert Enum.any?(lines, &(&1 =~ "walk started"))
      assert Enum.any?(lines, &(&1 =~ "walk finished"))
      refute Enum.any?(lines, &(&1 =~ u.id))
    end

    # CONTROL: this is what makes the tests below able to fail. The suite's
    # role sees the missing body, the migrator's role, with no tenant, does
    # not: a pre-check written this way would skip every database.
    test "CONTROL: an untenanted EXISTS is blind under RLS while rows need the split", %{
      user: u,
      vault: v
    } do
      _ = write!(u, v, "blind.md", "blind text")
      pre_split!(u)
      migrator!(false)

      assert Repo.query!(@blind_exists).rows == [[true]]
      assert as_migrator(fn -> Repo.query!(@blind_exists).rows end) == [[false]]
    end

    test "CONTROL: the migrator's role sees zero notes with no tenant", %{user: u, vault: v} do
      _ = write!(u, v, "zero.md", "zero text")
      migrator!(true)

      assert as_migrator(fn -> Repo.query!("SELECT count(*) FROM notes").rows end) == [[0]]
    end

    for maintenance? <- [true, false] do
      test "pre-split rows complete under RLS (maintenance member: #{maintenance?})", %{
        user: u,
        vault: v
      } do
        _ = write!(u, v, "split.md", "split text")
        written = bodies(u)
        pre_split!(u)
        assert bodies(u) == []
        migrator!(unquote(maintenance?))

        Engram.Fixtures.complete_split!(role: @migrator)

        assert bodies(u) == written
        assert read!(u, v, "split.md") == "split text"
      end

      test "a foreign-owner body is repaired under RLS (maintenance member: #{maintenance?})",
           %{user: u, vault: v} do
        note = write!(u, v, "owned.md", "owned text")
        foreign_body!(note)
        assert read!(u, v, "owned.md") == nil
        migrator!(unquote(maintenance?))

        Engram.Fixtures.complete_split!(role: @migrator)

        assert read!(u, v, "owned.md") == "owned text"
      end
    end
  end
end
