# Data-migrations ledger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One standard for self-healing data migrations: a `data_migrations` completion ledger, a behaviour, and one hourly runner, with the existing backfills moved onto it so none needs an operator and each stops once done.

**Architecture:** `Engram.DataMigrations` owns the ledger (`done?/2`, `mark_done/2`) plus two discovery helpers. Each migration is a module implementing `Engram.DataMigration` (`name/0`, `version/0`, `run_pass/0 :: :done | :more`). `Engram.Workers.DataMigrationsRunner` (hourly cron, `:maintenance`) skips every migration whose ledger row is done and runs one pass of the rest; a pass that finds zero work marks it done. `ReconcileEmbeddings` reads the ledger to stop its index-version scans once every note is current.

**Tech Stack:** Elixir, Ecto, Postgres 18, Oban cron. Run mix through `mise exec --` (OTP 27).

**Spec:** Engram vault `50 Engineering/_Superpowers Specs/2026-10-06-envelope-engine-and-data-migrations-design.md`, sections 5 and 9.1 (issue engram-app/Engram#1872, epic #609).

## Global Constraints

- Worktree `/home/open-claw/documents/code-projects/engram/.worktrees/data-migrations`, branch `feat/1872-data-migrations-ledger`. Never commit to main.
- `mise exec -- mix ...` for every mix command. Tests: `MIX_ENV=test mise exec -- mix test <files>`.
- Before push: `mise exec -- mix format --check-formatted`, `mise exec -- mix credo --strict`, `MIX_ENV=test mise exec -- mix compile --warnings-as-errors`, `mise exec -- mix sobelow --exit low --skip`, `mise exec -- mix dialyzer`.
- Upgrades need zero operator action; reads/behaviour must be correct whether or not a ledger row exists (the ledger only saves work).
- Cross-tenant discovery never uses `skip_tenant_check: true` on the app pool (it reads zero rows on prod, #1349): use `Repo.maintenance/0` or `Engram.Backfill.TenantScan`.
- Cron minutes: no two entries share a minute (`test/engram/oban_cron_test.exs`). The runner takes `"33 * * * *"`.
- `:maintenance` queue holds cron workers only (`test/engram/oban_queue_config_test.exs`).
- Commits: conventional, each ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01Asw3J7d43tbFAKR8GrroSX`.
- No em dashes in code comments or docs. Match the surrounding comment density.

## Review Focus

1. A newer release marked version 2 done, then a rollback runs version-1 code: `done?("x", 1)` must be true (stored version >= asked), so the old code does not redo work. Pinned in Task 1.
2. A pass that hits an error or a mid-rotation user must return `:more`, never `:done`, or the ledger closes over unfinished rows. Pinned in Tasks 3 and 4.
3. Re-enqueueing a backfill every hour while the previous chain is still running would duplicate jobs (those workers have no `unique`): the pass must return `:more` without enqueueing while jobs are in flight. Pinned in Task 4.
4. One migration raising must not stop the runner from running the others. Pinned in Task 2.
5. Notes that are content-current but carry a stale index version keep `IndexVersions` open; a note that is content-STALE (pending its first embed) must not, or the ledger never closes on an active install. Pinned in Task 5.

---

### Task 1: Ledger table and `Engram.DataMigrations`

**Files:**
- Create: `priv/repo/migrations/20261006170000_create_data_migrations_expand.exs`
- Create: `lib/engram/data_migrations/entry.ex`
- Create: `lib/engram/data_migrations.ex`
- Test: `test/engram/data_migrations_test.exs`

**Interfaces:**
- Produces:
  - `Engram.DataMigrations.done?(name :: String.t(), version :: pos_integer()) :: boolean()`
  - `Engram.DataMigrations.mark_done(name :: String.t(), version :: pos_integer()) :: :ok`
  - `Engram.DataMigrations.any_row?((Ecto.Repo.t() -> Ecto.Queryable.t())) :: boolean()`: true if the query built for a repo returns a row in ANY tenant.
  - `Engram.DataMigrations.jobs_in_flight?(worker :: module()) :: boolean()`
  - `Engram.DataMigrations.reset_cache() :: :ok` (`@doc false`, tests only)

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Engram.DataMigrationsTest do
  # async: false: done?/2 caches in :persistent_term, which is node-global.
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.DataMigrations
  alias Engram.Notes.Note

  setup do
    DataMigrations.reset_cache()
    :ok
  end

  describe "done?/2 and mark_done/2" do
    test "an unknown migration is not done" do
      refute DataMigrations.done?("never_seen", 1)
    end

    test "mark_done makes the same version done" do
      :ok = DataMigrations.mark_done("m", 1)
      assert DataMigrations.done?("m", 1)
    end

    test "a higher code version reopens it" do
      :ok = DataMigrations.mark_done("m", 1)
      refute DataMigrations.done?("m", 2)
    end

    test "a rollback to an older version still reads done" do
      :ok = DataMigrations.mark_done("m", 2)
      assert DataMigrations.done?("m", 1)
    end

    test "mark_done upserts the version forward" do
      :ok = DataMigrations.mark_done("m", 1)
      :ok = DataMigrations.mark_done("m", 2)
      assert DataMigrations.done?("m", 2)
      assert Repo.aggregate(Engram.DataMigrations.Entry, :count) == 1
    end

    test "a cached true survives without a DB read, and reset_cache clears it" do
      :ok = DataMigrations.mark_done("m", 1)
      assert DataMigrations.done?("m", 1)
      Repo.delete_all(Engram.DataMigrations.Entry)
      assert DataMigrations.done?("m", 1)
      DataMigrations.reset_cache()
      refute DataMigrations.done?("m", 1)
    end
  end

  describe "any_row?/1" do
    test "finds a row owned by any tenant" do
      user = insert(:user)
      insert(:note, user: user)
      assert DataMigrations.any_row?(fn _repo -> from(n in Note, select: 1) end)
    end

    test "is false on an empty set" do
      insert(:user)
      refute DataMigrations.any_row?(fn _repo -> from(n in Note, select: 1) end)
    end
  end

  describe "jobs_in_flight?/1" do
    test "sees an available job of that worker only" do
      refute DataMigrations.jobs_in_flight?(Engram.Workers.BackfillNoteLinks)

      %{"user_id" => Ecto.UUID.generate(), "vault_id" => Ecto.UUID.generate(), "cursor" => "", "scope" => "note_hmacs"}
      |> Engram.Workers.BackfillNoteLinks.new()
      |> Oban.insert!()

      assert DataMigrations.jobs_in_flight?(Engram.Workers.BackfillNoteLinks)
      refute DataMigrations.jobs_in_flight?(Engram.Workers.BackfillContentHashHmac)
    end
  end
end
```

Check `test/support/factory.ex` (or wherever `insert(:note, ...)` is defined) for the exact `:note` factory args; if `:note` needs a vault, use `vault = insert(:vault, user: user)` and `insert(:note, user: user, vault: vault)`. Check `Engram.Workers.BackfillNoteLinks`'s required args (`perform/1` pattern) and keep the map above in that shape. If the test env runs Oban in `:inline` or `:manual` testing mode such that `Oban.insert!` does not persist a row, use `Repo.insert!(Oban.Job.new(...))` instead; read `config/test.exs` first.

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mise exec -- mix test test/engram/data_migrations_test.exs`
Expected: FAIL, `Engram.DataMigrations` undefined.

- [ ] **Step 3: Write the migration**

```elixir
defmodule Engram.Repo.Migrations.CreateDataMigrationsExpand do
  use Ecto.Migration

  # phase/expand: completion ledger for self-healing data migrations (#1872).
  # One row per migration name. Global: no user_id, so no RLS
  # (test/engram/rls_coverage_test.exs only covers tables with user_id).
  # :timestamptz per Squawk's prefer-timestamp-tz.
  def change do
    create table(:data_migrations, primary_key: false) do
      add :name, :text, primary_key: true
      add :version, :integer, null: false
      add :completed_at, :timestamptz
      add :inserted_at, :timestamptz, null: false
      add :updated_at, :timestamptz, null: false
    end

    execute(
      "GRANT SELECT, INSERT, UPDATE, DELETE ON data_migrations TO engram_app",
      "REVOKE ALL ON data_migrations FROM engram_app"
    )
  end
end
```

Run `bash scripts/lint_migrations.sh` (or whatever `AGENTS.md` names for the migration linters) and fix what it reports before moving on.

- [ ] **Step 4: Write the schema**

```elixir
defmodule Engram.DataMigrations.Entry do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:name, :string, autogenerate: false}
  schema "data_migrations" do
    field :version, :integer
    field :completed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
```

- [ ] **Step 5: Write `Engram.DataMigrations`**

```elixir
defmodule Engram.DataMigrations do
  @moduledoc """
  Completion ledger for self-healing data migrations. See
  `docs/context/data-migrations-ledger.md`.

  A migration is done for `version` when its row holds that version or a
  higher one (a rollback to older code must not redo newer work) and
  `completed_at` is set. Bumping the version in code reopens it.

  The ledger only saves work: every reader must still handle rows in any
  older format, so a row an old node writes after `mark_done/2` is readable
  and the next version bump picks it up.
  """
  import Ecto.Query

  alias Engram.Backfill.TenantScan
  alias Engram.DataMigrations.Entry
  alias Engram.Repo

  @in_flight ~w(available scheduled executing retryable)

  @spec done?(String.t(), pos_integer()) :: boolean()
  def done?(name, version) do
    # Only `true` is cached: a migration never goes from done back to
    # not-done without a code change, and a code change restarts the node.
    case :persistent_term.get({__MODULE__, name, version}, false) do
      true ->
        true

      false ->
        done =
          Repo.exists?(
            from(e in Entry,
              where: e.name == ^name and e.version >= ^version and not is_nil(e.completed_at)
            )
          )

        if done, do: :persistent_term.put({__MODULE__, name, version}, true)
        done
    end
  end

  @spec mark_done(String.t(), pos_integer()) :: :ok
  def mark_done(name, version) do
    now = DateTime.utc_now()

    Repo.insert!(
      %Entry{name: name, version: version, completed_at: now},
      on_conflict: [set: [version: version, completed_at: now, updated_at: now]],
      conflict_target: :name
    )

    :ok
  end

  @doc """
  True if `query_for.(repo)` returns a row in any tenant. Uses the
  maintenance repo when enabled (one query), else one query per user inside
  that user's RLS context. Never trusts a cross-tenant read on the app pool,
  which FORCE RLS turns into zero rows (#1349).
  """
  @spec any_row?((module() -> Ecto.Queryable.t())) :: boolean()
  def any_row?(query_for) do
    case Repo.maintenance() do
      Repo ->
        TenantScan.flat_map_users(fn _user_id -> [Repo.exists?(query_for.(Repo))] end)
        |> Enum.any?()

      maintenance ->
        maintenance.exists?(query_for.(maintenance))
    end
  end

  @doc "True while any job of `worker` is queued or running."
  @spec jobs_in_flight?(module()) :: boolean()
  def jobs_in_flight?(worker) do
    name = worker |> Atom.to_string() |> String.replace_prefix("Elixir.", "")
    Repo.exists?(from(j in Oban.Job, where: j.worker == ^name and j.state in @in_flight))
  end

  @doc false
  def reset_cache do
    for {{__MODULE__, _, _} = key, _} <- :persistent_term.get(), do: :persistent_term.erase(key)
    :ok
  end
end
```

`TenantScan.flat_map_users/1` wraps a non-list return in a list; returning `[bool]` keeps the shape explicit. If `Repo.exists?` on `Oban.Job` trips the tenancy guard (`Engram.Repo.prepare_query/3`), pass `skip_tenant_check: true` for that one query only: `oban_jobs` has no RLS, so the #1349 trap does not apply. Say so in a comment if you add it.

- [ ] **Step 6: Run tests to verify they pass**

Run: `MIX_ENV=test mise exec -- mix test test/engram/data_migrations_test.exs test/engram/rls_coverage_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add priv/repo/migrations/20261006170000_create_data_migrations_expand.exs lib/engram/data_migrations.ex lib/engram/data_migrations/entry.ex test/engram/data_migrations_test.exs
git commit -m "feat(data-migrations): completion ledger table and API"
```

---

### Task 2: `Engram.DataMigration` behaviour and the hourly runner

**Files:**
- Create: `lib/engram/data_migration.ex`
- Create: `lib/engram/workers/data_migrations_runner.ex`
- Modify: `config/config.exs` (crontab, after the `{"28 * * * *", ...}` entry; also the minutes comment above `crontab:`)
- Test: `test/engram/workers/data_migrations_runner_test.exs`

**Interfaces:**
- Consumes: `DataMigrations.done?/2`, `DataMigrations.mark_done/2` (Task 1).
- Produces:
  - Behaviour `Engram.DataMigration` with callbacks `name() :: String.t()`, `version() :: pos_integer()`, `run_pass() :: :done | :more`.
  - `Engram.Workers.DataMigrationsRunner.migrations() :: [module()]`
  - `Engram.Workers.DataMigrationsRunner.run(module()) :: :skipped | :done | :more | :error`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Engram.Workers.DataMigrationsRunnerTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.DataMigrations
  alias Engram.Workers.DataMigrationsRunner

  defmodule Finished do
    @behaviour Engram.DataMigration
    def name, do: "test_finished"
    def version, do: 1
    def run_pass, do: :done
  end

  defmodule Unfinished do
    @behaviour Engram.DataMigration
    def name, do: "test_unfinished"
    def version, do: 1
    def run_pass, do: :more
  end

  defmodule Exploding do
    @behaviour Engram.DataMigration
    def name, do: "test_exploding"
    def version, do: 1
    def run_pass, do: raise("boom")
  end

  defmodule Counting do
    @behaviour Engram.DataMigration
    def name, do: "test_counting"
    def version, do: 1

    def run_pass do
      send(self(), :ran)
      :done
    end
  end

  setup do
    DataMigrations.reset_cache()
    :ok
  end

  test "a pass that finds no work marks it done" do
    assert DataMigrationsRunner.run(Finished) == :done
    assert DataMigrations.done?("test_finished", 1)
  end

  test "a pass with work left keeps it open" do
    assert DataMigrationsRunner.run(Unfinished) == :more
    refute DataMigrations.done?("test_unfinished", 1)
  end

  test "a done migration is skipped without running a pass" do
    :ok = DataMigrations.mark_done("test_counting", 1)
    assert DataMigrationsRunner.run(Counting) == :skipped
    refute_received :ran
  end

  test "a raising migration is contained and stays open" do
    assert DataMigrationsRunner.run(Exploding) == :error
    refute DataMigrations.done?("test_exploding", 1)
  end

  test "perform runs every registered migration" do
    assert :ok = perform_job(DataMigrationsRunner, %{})
  end

  test "every registered module implements the behaviour" do
    for mod <- DataMigrationsRunner.migrations() do
      assert Engram.DataMigration in Keyword.get_values(mod.__info__(:attributes), :behaviour)
             |> List.flatten(),
             inspect(mod)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mise exec -- mix test test/engram/workers/data_migrations_runner_test.exs`
Expected: FAIL, `Engram.Workers.DataMigrationsRunner` undefined.

- [ ] **Step 3: Write the behaviour**

```elixir
defmodule Engram.DataMigration do
  @moduledoc """
  A self-healing data migration, run by `Engram.Workers.DataMigrationsRunner`
  until a pass finds no work. See `docs/context/data-migrations-ledger.md`.

  `run_pass/0` does (or enqueues) one bounded slice of work and returns
  `:done` ONLY when it found nothing left to do. Anything uncertain (an
  error, a user skipped mid-rotation, jobs still running) is `:more`.
  """
  @callback name() :: String.t()
  @callback version() :: pos_integer()
  @callback run_pass() :: :done | :more
end
```

- [ ] **Step 4: Write the runner**

```elixir
defmodule Engram.Workers.DataMigrationsRunner do
  @moduledoc """
  Hourly cron: one pass of every registered `Engram.DataMigration` whose
  ledger row is not done (`Engram.DataMigrations`). Each runs isolated: one
  raising does not stop the rest.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3000]

  alias Engram.DataMigrations
  alias Engram.Logger.Metadata

  require Logger

  # Task 3-5 append their modules here.
  @migrations []

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  def migrations, do: @migrations

  @impl Oban.Worker
  def perform(_job) do
    Enum.each(@migrations, &run/1)
  end

  @spec run(module()) :: :skipped | :done | :more | :error
  def run(mod) do
    {name, version} = {mod.name(), mod.version()}

    if DataMigrations.done?(name, version) do
      :skipped
    else
      case mod.run_pass() do
        :done ->
          :ok = DataMigrations.mark_done(name, version)
          Logger.info("data migration done", Metadata.with_category(:info, :maintenance, migration: name, version: version))
          :done

        :more ->
          :more
      end
    end
  rescue
    e ->
      Logger.warning(
        "data migration pass failed",
        Metadata.with_category(:warning, :maintenance,
          migration: inspect(mod),
          reason: Metadata.safe_reason(e)
        )
      )

      :error
  end
end
```

Check `Engram.Logger.Metadata.with_category/3` accepts `:maintenance` as a category (grep its allowed categories). If it does not, use the category the existing `:maintenance`-queue workers use (e.g. `CrdtBloatSweep`).

- [ ] **Step 5: Add the cron entry**

In `config/config.exs`, after `{"28 * * * *", Engram.Workers.InstallPingsPruner},` add:

```elixir
        # Self-healing data migrations (#1872): one pass of each one whose
        # ledger row is not done; a pass that finds no work closes it.
        {"33 * * * *", Engram.Workers.DataMigrationsRunner},
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `MIX_ENV=test mise exec -- mix test test/engram/workers/data_migrations_runner_test.exs test/engram/oban_cron_test.exs test/engram/oban_queue_config_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/engram/data_migration.ex lib/engram/workers/data_migrations_runner.ex config/config.exs test/engram/workers/data_migrations_runner_test.exs
git commit -m "feat(data-migrations): behaviour and hourly runner"
```

---

### Task 3: Move the vault-slug backfill onto the ledger

**Files:**
- Create: `lib/engram/data_migrations/vault_slug_hmac.ex`
- Delete: `lib/engram/workers/backfill_vault_slug_hmac.ex`
- Move: `test/engram/workers/backfill_vault_slug_hmac_test.exs` -> `test/engram/data_migrations/vault_slug_hmac_test.exs`
- Modify: `config/config.exs` (delete the `{"25 4 * * *", Engram.Workers.BackfillVaultSlugHmac}` entry and its 3-line comment)
- Modify: `lib/engram/workers/data_migrations_runner.ex` (`@migrations`)
- Modify: comments naming `BackfillVaultSlugHmac` in `lib/engram/vaults.ex` (~line 897) and `lib/engram/vaults/vault.ex` (~line 15): point them at `Engram.DataMigrations.VaultSlugHmac`.

**Interfaces:**
- Consumes: `Engram.DataMigration` (Task 2), `Vaults.backfill_slug_hmacs/1 :: {:ok, non_neg_integer()} | {:error, :rotation_in_progress} | {:error, term()}`.
- Produces: `Engram.DataMigrations.VaultSlugHmac` (`name/0` = `"vault_slug_hmac"`, `version/0` = `1`).

- [ ] **Step 1: Move and retarget the test**

`git mv test/engram/workers/backfill_vault_slug_hmac_test.exs test/engram/data_migrations/vault_slug_hmac_test.exs`. In it:
- Rename the module to `Engram.DataMigrations.VaultSlugHmacTest`; alias `Engram.DataMigrations.VaultSlugHmac` instead of the worker; drop `use Oban.Testing` if nothing else uses it.
- Replace every `assert :ok = perform_job(BackfillVaultSlugHmac, %{})` with `assert VaultSlugHmac.run_pass() == :more` when that call clears at least one row, and `== :done` when the test expects nothing cleared.
- Add:

```elixir
  describe "completion" do
    test "a pass that clears rows is :more, the next one is :done" do
      user = insert(:user)
      {:ok, vault, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      set_raw(vault.id, slug: "notes")

      assert VaultSlugHmac.run_pass() == :more
      assert VaultSlugHmac.run_pass() == :done
    end

    test "a user mid-rotation keeps it open" do
      user = insert(:user)
      {:ok, vault, _} = Vaults.register_vault(user, "Notes", Ecto.UUID.generate())
      set_raw(vault.id, slug: "notes")
      # Put the user in the state Vaults.backfill_slug_hmacs/1 reports as
      # {:error, :rotation_in_progress}: read that function and the existing
      # rotation test in this file (if any) for how; set_raw-style direct
      # update of the users row is fine.
      mark_rotation_in_progress(user)

      assert VaultSlugHmac.run_pass() == :more
    end
  end
```

Implement `mark_rotation_in_progress/1` as a private helper in the test, after reading how `Vaults.backfill_slug_hmacs/1` detects a rotation (grep `rotation_in_progress` in `lib/engram/vaults.ex` and `lib/engram/crypto/rotation_gate.ex`).

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_ENV=test mise exec -- mix test test/engram/data_migrations/vault_slug_hmac_test.exs`
Expected: FAIL, `Engram.DataMigrations.VaultSlugHmac` undefined.

- [ ] **Step 3: Write the migration module**

```elixir
defmodule Engram.DataMigrations.VaultSlugHmac do
  @moduledoc """
  Clears the plaintext `vaults.slug`, first making `slug_hmac` /
  `slug_suffixed` describe the derived slug; see `Vaults.backfill_slug_hmacs/1`.

  The HMAC needs each user's DEK-derived filter key, so it cannot run in the
  migration. Done when a pass clears nothing for every user. Users with
  nothing to clear derive no key. A user mid-DEK-rotation or a failed user
  keeps it open for the next pass. Removed with the contract release that
  drops `vaults.slug`.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Logger.Metadata
  alias Engram.Repo
  alias Engram.Vaults

  require Logger

  @impl true
  def name, do: "vault_slug_hmac"

  @impl true
  def version, do: 1

  @impl true
  def run_pass do
    # `users` is not RLS-scoped; the per-user vault work runs under with_tenant.
    Repo.all(from(u in User, where: is_nil(u.deleted_at), order_by: u.id, select: u.id))
    |> Enum.map(&backfill_user/1)
    |> Enum.all?(&(&1 == :clean))
    |> if(do: :done, else: :more)
  end

  # Each user runs in its own transaction; one user's failure (a returned
  # error such as a KMS outage or missing DEK, or a raise such as a unique
  # violation on a hand-edited slug) is logged and must not starve the rest.
  defp backfill_user(user_id) do
    case Vaults.backfill_slug_hmacs(user_id) do
      {:ok, 0} ->
        :clean

      {:ok, count} ->
        Logger.info(
          "vault slugs reconciled",
          Metadata.with_category(:info, :crypto, user_id: user_id, reconciled: count)
        )

        :changed

      {:error, :rotation_in_progress} ->
        :skipped

      {:error, reason} ->
        log_failure(user_id, reason)
    end
  rescue
    e -> log_failure(user_id, e)
  end

  defp log_failure(user_id, reason) do
    Logger.warning(
      "vault slug reconcile failed",
      Metadata.with_category(:warning, :crypto,
        user_id: user_id,
        reason: Metadata.safe_reason(reason)
      )
    )

    :failed
  end
end
```

- [ ] **Step 4: Register it, delete the old worker and cron entry**

- `@migrations [Engram.DataMigrations.VaultSlugHmac]` in the runner.
- `git rm lib/engram/workers/backfill_vault_slug_hmac.ex`
- Delete the `{"25 4 * * *", Engram.Workers.BackfillVaultSlugHmac},` line and its comment in `config/config.exs`.
- Update the two comments in `lib/engram/vaults.ex` and `lib/engram/vaults/vault.ex`.
- `grep -rn BackfillVaultSlugHmac lib test config priv docs` must return only migration-file comments (leave those: migrations are immutable).

- [ ] **Step 5: Run tests to verify they pass**

Run: `MIX_ENV=test mise exec -- mix test test/engram/data_migrations/ test/engram/workers/data_migrations_runner_test.exs test/engram/oban_cron_test.exs test/engram/oban_queue_config_test.exs test/engram/vaults_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A lib/engram/data_migrations lib/engram/workers config/config.exs test/engram/data_migrations test/engram/workers lib/engram/vaults.ex lib/engram/vaults/vault.ex
git commit -m "refactor(vaults): slug HMAC backfill runs on the data-migrations ledger"
```

---

### Task 4: Content-hash HMAC and note-link HMAC backfills, no operator step

**Files:**
- Create: `lib/engram/data_migrations/content_hash_hmac.ex`
- Create: `lib/engram/data_migrations/note_link_hmacs.ex`
- Modify: `lib/engram/workers/data_migrations_runner.ex` (`@migrations`)
- Test: `test/engram/data_migrations/content_hash_hmac_test.exs`, `test/engram/data_migrations/note_link_hmacs_test.exs`

**Interfaces:**
- Consumes: `DataMigrations.jobs_in_flight?/1`, `DataMigrations.any_row?/1` (Task 1); `Engram.ContentHash.Backfill.enqueue_all/0 :: %{notes: non_neg_integer(), attachments: non_neg_integer()}` (pair counts with legacy MD5 hashes); `Engram.Links.Backfill.enqueue_all/0 :: non_neg_integer()`.
- Produces: `Engram.DataMigrations.ContentHashHmac` (`"content_hash_hmac"`, 1), `Engram.DataMigrations.NoteLinkHmacs` (`"note_link_hmacs"`, 1).

The mix tasks (`mix engram.content_hash_hmac`, `mix engram.backfill_note_links`) stay as manual escape hatches.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Engram.DataMigrations.ContentHashHmacTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Engram.Fixtures

  alias Engram.Crypto
  alias Engram.DataMigrations.ContentHashHmac
  alias Engram.Notes.Note
  alias Engram.Workers.BackfillContentHashHmac

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "DM", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "no legacy hashes: done, nothing enqueued" do
    assert ContentHashHmac.run_pass() == :done
    refute_enqueued(worker: BackfillContentHashHmac)
  end

  test "a legacy MD5 hash enqueues the backfill and stays open", %{user: user, vault: vault} do
    note = insert_legacy_md5_note(user, vault)
    assert ContentHashHmac.run_pass() == :more
    assert_enqueued(worker: BackfillContentHashHmac, args: %{"user_id" => user.id, "vault_id" => vault.id})
    assert note
  end

  test "jobs in flight: stays open without enqueueing again", %{user: user, vault: vault} do
    insert_legacy_md5_note(user, vault)
    assert ContentHashHmac.run_pass() == :more
    assert ContentHashHmac.run_pass() == :more
    assert length(all_enqueued(worker: BackfillContentHashHmac)) == 2
  end
end
```

`insert_legacy_md5_note/2`: copy how `test/engram/workers/backfill_content_hash_hmac_test.exs` creates a note with a 32-char hex `content_hash` (it already does exactly this; reuse its helper or its body verbatim). The `== 2` in the last test is the notes scope plus attachments scope count from ONE `enqueue_all/0` call for a vault with only notes: read `enqueue_all/0` and set the number to what one call inserts for this fixture (1 if attachments with no legacy rows enqueue nothing, which `legacy_pairs/1` implies). The point of the test is that the second pass adds zero jobs.

```elixir
defmodule Engram.DataMigrations.NoteLinkHmacsTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.DataMigrations.NoteLinkHmacs
  alias Engram.Notes.Note
  alias Engram.Workers.BackfillNoteLinks

  test "every note has a basename_hmac: done" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    insert(:note, user: user, vault: vault)
    assert NoteLinkHmacs.run_pass() == :done
    refute_enqueued(worker: BackfillNoteLinks)
  end

  test "a note missing basename_hmac enqueues the chain and stays open" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)

    Repo.update_all(from(n in Note, where: n.id == ^note.id), [set: [basename_hmac: nil]],
      skip_tenant_check: true
    )

    assert NoteLinkHmacs.run_pass() == :more
    assert_enqueued(worker: BackfillNoteLinks)
    assert NoteLinkHmacs.run_pass() == :more
    assert length(all_enqueued(worker: BackfillNoteLinks)) == 1
  end
end
```

Check the `:note` factory sets `path_ciphertext` and `basename_hmac`; if it leaves `basename_hmac` nil, the first test must set it (copy how `test/engram/workers/backfill_note_links_test.exs` builds a fully-formed note).

- [ ] **Step 2: Run tests to verify they fail**

Run: `MIX_ENV=test mise exec -- mix test test/engram/data_migrations/content_hash_hmac_test.exs test/engram/data_migrations/note_link_hmacs_test.exs`
Expected: FAIL, modules undefined.

- [ ] **Step 3: Write the two modules**

```elixir
defmodule Engram.DataMigrations.ContentHashHmac do
  @moduledoc """
  Legacy MD5 `content_hash` values become HMAC-SHA256 (Phase A). Each pass
  enqueues the `BackfillContentHashHmac` chain for every (user, vault) with a
  legacy hash, unless a chain is still running. Done when no row in any
  tenant holds a 32-char hash.
  """
  @behaviour Engram.DataMigration

  alias Engram.ContentHash.Backfill
  alias Engram.DataMigrations
  alias Engram.Workers.BackfillContentHashHmac

  @impl true
  def name, do: "content_hash_hmac"

  @impl true
  def version, do: 1

  @impl true
  def run_pass do
    # The worker has no `unique` (#1230): enqueueing while a chain runs
    # would duplicate it.
    if DataMigrations.jobs_in_flight?(BackfillContentHashHmac) do
      :more
    else
      case Backfill.enqueue_all() do
        %{notes: 0, attachments: 0} -> :done
        _ -> :more
      end
    end
  end
end
```

```elixir
defmodule Engram.DataMigrations.NoteLinkHmacs do
  @moduledoc """
  Rows predating link extraction (#591) have a NULL `basename_hmac` and no
  `note_links` edges. Each pass enqueues the `BackfillNoteLinks` chain,
  unless one is still running. Done when no note or attachment in any tenant
  lacks a `basename_hmac`.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.DataMigrations
  alias Engram.Links.Backfill
  alias Engram.Notes.Note
  alias Engram.Workers.BackfillNoteLinks

  @impl true
  def name, do: "note_link_hmacs"

  @impl true
  def version, do: 1

  @impl true
  def run_pass do
    cond do
      DataMigrations.jobs_in_flight?(BackfillNoteLinks) ->
        :more

      missing_hmacs?() ->
        Backfill.enqueue_all()
        :more

      true ->
        :done
    end
  end

  # The same predicates as the worker's note_hmacs and attachment_hmacs scopes.
  defp missing_hmacs? do
    DataMigrations.any_row?(fn _repo ->
      from(n in Note,
        where: n.kind == "note" and is_nil(n.basename_hmac) and not is_nil(n.path_ciphertext),
        select: 1
      )
    end) or
      DataMigrations.any_row?(fn _repo ->
        from(a in Attachment,
          where: is_nil(a.basename_hmac) and not is_nil(a.path_ciphertext),
          select: 1
        )
      end)
  end
end
```

Verify the aliases (`Engram.Attachments.Attachment`) and the predicates against `lib/engram/workers/backfill_note_links.ex` (scopes `"note_hmacs"` ~line 151 and `"attachment_hmacs"` ~line 169); if they differ, copy the worker's.

- [ ] **Step 4: Register both**

`@migrations [Engram.DataMigrations.VaultSlugHmac, Engram.DataMigrations.ContentHashHmac, Engram.DataMigrations.NoteLinkHmacs]`

- [ ] **Step 5: Run tests to verify they pass**

Run: `MIX_ENV=test mise exec -- mix test test/engram/data_migrations/ test/engram/workers/data_migrations_runner_test.exs test/engram/workers/backfill_content_hash_hmac_test.exs test/engram/workers/backfill_note_links_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/engram/data_migrations lib/engram/workers/data_migrations_runner.ex test/engram/data_migrations
git commit -m "feat(data-migrations): content-hash and note-link HMAC backfills need no operator"
```

---

### Task 5: Index versions: stop the version scans once every note is current

**Files:**
- Create: `lib/engram/data_migrations/index_versions.ex`
- Modify: `lib/engram/workers/reconcile_embeddings.ex` (`version_stale_dynamic/0` at ~352-373 moves out; the call at ~97; `sweep_keyword_stale/3` at ~395 and its caller; the keyword predicate inside it)
- Modify: `lib/engram/workers/data_migrations_runner.ex` (`@migrations`)
- Test: `test/engram/data_migrations/index_versions_test.exs`; extend `test/engram/workers/reconcile_embeddings_test.exs`

**Interfaces:**
- Consumes: `DataMigrations.done?/2`, `DataMigrations.any_row?/1`; `Engram.Parsers.Markdown.chunker_version/0`, `Engram.KeywordIndex.version/0`, `Engram.Indexing.embed_model/0 :: String.t() | nil`.
- Produces:
  - `Engram.DataMigrations.IndexVersions.name/0 :: String.t()`: `"index_versions:chunker=#{c},keyword=#{k},model=#{m || "none"}"`, so a bump of any of the three is a new name (not done).
  - `IndexVersions.version/0 :: 1`
  - `IndexVersions.done?/0 :: boolean()` (`DataMigrations.done?(name(), version())`)
  - `IndexVersions.stale_dynamic/0 :: Ecto.Query.dynamic_expr()`: the exact body of today's `ReconcileEmbeddings.version_stale_dynamic/0`.
  - `IndexVersions.keyword_stale_dynamic/0`: `is_nil(n.keyword_version) or n.keyword_version != ^KeywordIndex.version()`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Engram.DataMigrations.IndexVersionsTest do
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.DataMigrations
  alias Engram.DataMigrations.IndexVersions
  alias Engram.Notes.Note

  setup do
    DataMigrations.reset_cache()
    user = insert(:user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp set!(note, fields),
    do: Repo.update_all(from(n in Note, where: n.id == ^note.id), [set: fields], skip_tenant_check: true)

  defp current!(note) do
    set!(note,
      content_hash: "h",
      embed_hash: "h",
      dense_indexed_hash: "h",
      chunker_version: Engram.Parsers.Markdown.chunker_version(),
      keyword_version: Engram.KeywordIndex.version(),
      embed_model: Engram.Indexing.embed_model()
    )
  end

  test "the name changes when a version changes" do
    assert IndexVersions.name() =~ "chunker=#{Engram.Parsers.Markdown.chunker_version()}"
    assert IndexVersions.name() =~ "keyword=#{Engram.KeywordIndex.version()}"
  end

  test "every note current: done", %{user: u, vault: v} do
    current!(insert(:note, user: u, vault: v))
    assert IndexVersions.run_pass() == :done
  end

  test "a content-current note on an old chunker keeps it open", %{user: u, vault: v} do
    note = insert(:note, user: u, vault: v)
    current!(note)
    set!(note, chunker_version: Engram.Parsers.Markdown.chunker_version() - 1)
    assert IndexVersions.run_pass() == :more
  end

  test "a content-current note on an old keyword version keeps it open", %{user: u, vault: v} do
    note = insert(:note, user: u, vault: v)
    current!(note)
    set!(note, keyword_version: nil)
    assert IndexVersions.run_pass() == :more
  end

  test "a note waiting for its first embed does not keep it open", %{user: u, vault: v} do
    note = insert(:note, user: u, vault: v)
    set!(note, content_hash: "new", embed_hash: nil, chunker_version: nil, keyword_version: nil)
    assert IndexVersions.run_pass() == :done
  end

  test "a deleted note does not keep it open", %{user: u, vault: v} do
    note = insert(:note, user: u, vault: v)
    current!(note)
    set!(note, chunker_version: 0, deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
    assert IndexVersions.run_pass() == :done
  end
end
```

In `test/engram/workers/reconcile_embeddings_test.exs`, add one test next to the existing chunker-version test (read it first and reuse its setup and assertion style):

```elixir
  test "once IndexVersions is done, a version-stale note is not swept" do
    # Same setup as the existing "stale chunker_version" test in this file.
    # Then:
    :ok = Engram.DataMigrations.mark_done(Engram.DataMigrations.IndexVersions.name(), 1)
    # perform the sweep exactly as that test does, and assert NO
    # RebuildStaleNote / RefreshKeywordVectors job is enqueued for the note.
  end
```

Write it as real code by copying the existing test's body and flipping its final assertion to `refute_enqueued`; add `Engram.DataMigrations.reset_cache()` to that file's `setup` so the cached flag cannot leak between tests.

- [ ] **Step 2: Run tests to verify they fail**

Run: `MIX_ENV=test mise exec -- mix test test/engram/data_migrations/index_versions_test.exs test/engram/workers/reconcile_embeddings_test.exs`
Expected: FAIL (`IndexVersions` undefined; the new reconcile test enqueues a job).

- [ ] **Step 3: Write `IndexVersions`**

```elixir
defmodule Engram.DataMigrations.IndexVersions do
  @moduledoc """
  Every note indexed with the current chunker, keyword encoding and embed
  model. `ReconcileEmbeddings` does the rebuilding (see
  `docs/context/index-version-self-heal.md`); this only decides when no
  content-current note is left on an old version, so the reconcile cron can
  stop scanning for them. The name carries the three versions: bumping any
  of them is a new, not-done migration.
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.DataMigrations
  alias Engram.Indexing
  alias Engram.KeywordIndex
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Vaults.Vault

  @impl true
  def name,
    do:
      "index_versions:chunker=#{Markdown.chunker_version()},keyword=#{KeywordIndex.version()}," <>
        "model=#{Indexing.embed_model() || "none"}"

  @impl true
  def version, do: 1

  @spec done?() :: boolean()
  def done?, do: DataMigrations.done?(name(), version())

  # Content-stale notes are excluded: the live sweep embeds them, which
  # stamps current versions. Counting them would hold this open on every
  # install that is being written to.
  @impl true
  def run_pass do
    stale =
      DataMigrations.any_row?(fn _repo ->
        from(n in Note, as: :note)
        |> join(:inner, [n], v in Vault, on: v.id == n.vault_id and is_nil(v.deleted_at))
        |> where([n], n.kind == "note" and is_nil(n.deleted_at))
        |> where([n], not is_nil(n.embed_hash) and n.embed_hash == n.content_hash)
        |> where(^dynamic([n], ^stale_dynamic() or ^keyword_stale_dynamic()))
        |> select(1)
      end)

    if stale, do: :more, else: :done
  end

  # Moved verbatim from ReconcileEmbeddings.version_stale_dynamic/0.
  def stale_dynamic do
    chunker = Markdown.chunker_version()
    chunker_stale = dynamic([n], is_nil(n.chunker_version) or n.chunker_version != ^chunker)

    case Indexing.embed_model() do
      # The build cannot name its model: model tracking is off.
      nil ->
        chunker_stale

      model ->
        # `not is_nil` first: on a sparse-only note `dense = content` is NULL,
        # and the keyword sweep negates this predicate, where NOT (NULL)
        # silently drops the row. Every term here must be TRUE or FALSE.
        dynamic(
          [n],
          ^chunker_stale or
            (not is_nil(n.dense_indexed_hash) and not is_nil(n.content_hash) and
               n.dense_indexed_hash == n.content_hash and
               (is_nil(n.embed_model) or n.embed_model != ^model))
        )
    end
  end

  def keyword_stale_dynamic do
    version = KeywordIndex.version()
    dynamic([n], is_nil(n.keyword_version) or n.keyword_version != ^version)
  end
end
```

- [ ] **Step 4: Gate `ReconcileEmbeddings` on it**

In `lib/engram/workers/reconcile_embeddings.ex`:
- Delete `defp version_stale_dynamic` and replace its three call sites with `IndexVersions.stale_dynamic()` (alias `Engram.DataMigrations.IndexVersions`).
- In the keyword sweep, replace `where([n], is_nil(n.keyword_version) or n.keyword_version != ^version)` with `where(^IndexVersions.keyword_stale_dynamic())` and drop the now-unused `version` binding if nothing else reads it.
- At the top of the main sweep (around line 97), compute `versions_done = IndexVersions.done?()` once per `perform`, then:

```elixir
    # Once IndexVersions is done no content-current note is on an old
    # version: skip the version term and the keyword scan (an unindexed
    # per-tenant scan every 5 min). A version bump renames the migration,
    # which reopens both.
    version_stale = if versions_done, do: dynamic(false), else: IndexVersions.stale_dynamic()
```

- Wrap the `sweep_keyword_stale(...)` call: `unless versions_done, do: sweep_keyword_stale(...)`, keeping its return contract (if its result is pattern-matched, return the same success value it returns on an empty sweep).
- Register: `@migrations [Engram.DataMigrations.IndexVersions, Engram.DataMigrations.VaultSlugHmac, Engram.DataMigrations.ContentHashHmac, Engram.DataMigrations.NoteLinkHmacs]`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `MIX_ENV=test mise exec -- mix test test/engram/data_migrations/ test/engram/workers/reconcile_embeddings_test.exs test/engram/workers/reconcile_embeddings_maintenance_test.exs test/engram/workers/data_migrations_runner_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/engram/data_migrations/index_versions.ex lib/engram/workers/reconcile_embeddings.ex lib/engram/workers/data_migrations_runner.ex test/engram/data_migrations/index_versions_test.exs test/engram/workers/reconcile_embeddings_test.exs
git commit -m "perf(indexing): stop index-version scans once every note is current"
```

---

### Task 6: Document the standard and run the gates

**Files:**
- Create: `docs/context/data-migrations-ledger.md`
- Modify: `AGENTS.md` (next to the zero-operator-action upgrade rule)
- Modify: `docs/context/index-version-self-heal.md` (one paragraph: the ledger stops the version scans)

- [ ] **Step 1: Write `docs/context/data-migrations-ledger.md`**

Cover, in this order, with no em dashes:
1. The rule: a data migration that must reach existing rows is an `Engram.DataMigration` module registered in `DataMigrationsRunner.@migrations`. Never an operator command, never a one-off rpc.
2. The contract: `run_pass/0` returns `:done` only when it found no work; errors, rotation skips and in-flight jobs are `:more`. Readers handle every older format, so the ledger only saves work.
3. Versioning: bump `version/0` (or, for `IndexVersions`, the version constants inside `name/0`) to reopen. `done?/2` treats a stored higher version as done, so a rollback does not redo work.
4. Cross-tenant discovery: `DataMigrations.any_row?/1`, never `skip_tenant_check: true` on the app pool (#1349).
5. Jobs without `unique`: guard with `DataMigrations.jobs_in_flight?/1` before enqueueing.
6. Current migrations: the four modules and what each covers. Not on the ledger, and why: `BackfillCrdtHead` (a continuing self-heal: any crdt_state write NULLs `crdt_head`), `BackfillCrdtState` (a repair tool that must not run unsupervised; `user_dek_rotation.ex` ~140), `ReindexKeyword` (operator tool; `IndexVersions` covers keyword-version changes).
7. Next user: the envelope format backfill (#1872 PR 3).

- [ ] **Step 2: Add the AGENTS.md pointer**

One line next to the zero-operator-action rule: `- Backfills that must reach existing rows are \`Engram.DataMigration\` modules on the completion ledger; see docs/context/data-migrations-ledger.md.`

- [ ] **Step 3: Update `docs/context/index-version-self-heal.md`**

Add: once `Engram.DataMigrations.IndexVersions` is done, `ReconcileEmbeddings` drops the version term and skips the keyword scan; bumping the chunker, keyword or model version renames the migration and reopens both. Remove any instruction that tells an operator to run `ReindexKeyword :sparse` for a version bump.

- [ ] **Step 4: Run every gate**

```bash
mise exec -- mix format --check-formatted
mise exec -- mix credo --strict
MIX_ENV=test mise exec -- mix compile --warnings-as-errors
mise exec -- mix sobelow --exit low --skip
mise exec -- mix dialyzer
MIX_ENV=test mise exec -- mix test test/engram/data_migrations/ test/engram/data_migrations_test.exs test/engram/workers/ test/engram/oban_cron_test.exs test/engram/oban_queue_config_test.exs test/engram/rls_coverage_test.exs test/engram/vaults_test.exs
```

Expected: all clean. If sobelow reports fingerprints moved by line shifts, regenerate with `rm .sobelow-skips && mise exec -- mix sobelow --mark-skip-all` and check the diff only moved line numbers.

- [ ] **Step 5: Commit**

```bash
git add docs/context/data-migrations-ledger.md AGENTS.md docs/context/index-version-self-heal.md
git commit -m "docs: the data-migrations ledger standard"
```

---

## Round 2 (2026-10-06, after review): prune, cover every backfill, startup run, stuck flags

Prod audit (read-only, 4,338 live notes): legacy MD5 hashes 0, missing basename_hmac 0, plaintext vault slugs 0, version-stale 0; NULL `crdt_state_ciphertext` 8; NULL `crdt_head` 1,095. Assumption from here on: no self-hosters exist today, so finished one-time backfills are deleted, not ported. After this PR, assume self-hosters exist.

### Task 7: Delete the finished backfills

**Delete** (code, tests, mix tasks, docs references, runner registration):
- `Engram.DataMigrations.ContentHashHmac`, `Engram.Workers.BackfillContentHashHmac`, `Engram.ContentHash.Backfill`, `lib/mix/tasks/engram.content_hash_hmac.ex`.
- `Engram.DataMigrations.NoteLinkHmacs`, `Engram.Workers.BackfillNoteLinks`, `Engram.Links.Backfill`, `lib/mix/tasks/engram.backfill_note_links.ex`.
- `Engram.DataMigrations.VaultSlugHmac`, `Vaults.backfill_slug_hmacs/1` and its private helpers, their tests. The `vaults.slug` column itself stays (its contract-phase drop is separate).
- `Engram.Workers.ReindexKeyword` and its tests. Keep `RefreshKeywordVectors` (ReconcileEmbeddings uses it).

**Rules:**
- Grep every reference first (`lib test config .github docs AGENTS.md`); `.github/workflows/verify.yml` names `ContentHash.Backfill` and `Links.Backfill`: read why and update it.
- Update comments that point at deleted modules; never edit `priv/repo/migrations`.
- Do NOT remove read-side compatibility code (e.g. code that still accepts a 32-char MD5 hash, or reads `vaults.slug`). List such places in the report instead; a later contract PR removes them.
- If a deleted module's test file also covers behaviour that still exists elsewhere, move those cases, don't drop them.
- `@migrations` becomes `[Engram.DataMigrations.IndexVersions]` (Task 8 adds more). Update the order test.
- Docs: `data-migrations-ledger.md` and `AGENTS.md` lose the deleted entries; add a short "Pruned" note listing them with the prod audit date, so nobody re-adds them.

**Tests:** full `test/engram/` subtree that referenced the deleted modules still passes; `mix compile --warnings-as-errors` clean.

### Task 8: Put the remaining CRDT backfills on the system

**CRDT state (repair, done-able):** register `Engram.DataMigrations.CrdtStateSeed` (`"crdt_state_seed"`, 1) that drives the existing `Engram.Workers.BackfillCrdtState`.
- First read the worker and the warning at `lib/engram/crypto/user_dek_rotation.ex` ~140 and `lib/engram/crypto/aad_rebind.ex` ~220: seeding a lineage from content is wrong for a note whose real state is an un-checkpointed tail in `crdt_update_log`. The worker must only seed notes with NO tail rows. If it does not already guarantee that, add the guard in the worker's per-batch predicate (TDD: a NULL-state note WITH a tail row is not seeded).
- `run_pass/0`: `jobs_in_flight?(BackfillCrdtState)` -> `:more`; else enqueue only pairs that have a seedable note (NULL state, kind note, not deleted, live vault, no tail rows), `:done` when there are none. Reuse/adapt `BackfillCrdtState.enqueue_all/0` into a targeted function, same pattern as round 1's ContentHash targeting.
- Notes with NULL state AND a tail are not this migration's work (tail replay serves them); they are excluded from the done predicate.

**CRDT head (continuing self-heal, never done):** heads go NULL on every edit and only `BackfillCrdtHead` re-warms them (no schedule today; 25% NULL in prod).
- Add a cron worker `Engram.Workers.WarmCrdtHeads` on `:maintenance`, hourly at a free minute (check `oban_cron_test.exs` and the Minutes comment; :x3/:x8 pattern), which calls `BackfillCrdtHead.enqueue_all/0` unless `DataMigrations.jobs_in_flight?(Engram.Workers.BackfillCrdtHead)`.
- It is not a DataMigration (it never finishes); document it in `data-migrations-ledger.md` under "continuing self-heals" so the distinction is explicit.
- Tests: enqueues when a NULL-head note exists; no-op while jobs in flight; no-op with no NULL heads.

### Task 9: Run the runner at startup

- Add `{"@reboot", Engram.Workers.DataMigrationsRunner}` to the crontab (Oban Cron supports `@reboot`). Check `test/engram/oban_cron_test.exs` parses it; if its minute-slot logic chokes on `@reboot`, teach it to skip `@reboot` entries (they hold no minute), with a test.
- The hourly entry stays. `unique: [period: 3000]` on the runner already prevents a boot run and the hourly run from overlapping; confirm a boot within the hour of a run is deduplicated, and say in the doc that this is intended.
- Docs: ledger doc "When it runs" = at boot and hourly.

### Task 10: Flag stuck migrations for review

- Migration `20261006170000_create_data_migrations_expand.exs` has not shipped: edit it in place to add `opened_at timestamptz` and `alerted_at timestamptz`. Update `Entry`.
- `DataMigrations`: `note_open(name, version)` upserts the row with `completed_at` nil when a pass returns `:more` or `:error`; it sets `opened_at = now()` on insert or when the stored version is lower (a reopen), and leaves `opened_at` alone otherwise.
- Runner: after a `:more`/`:error` pass, if `now - opened_at > @stuck_after` (7 days) and (`alerted_at` nil or older than 24 h), log at `:error` "data migration stuck" with name, version, opened_at (Sentry picks up `:error`), then set `alerted_at`. One alert per migration per day.
- Tests: an open migration younger than 7 days logs nothing; older logs once and not again within 24 h; a version bump resets `opened_at`; `mark_done` leaves the row closed.
- Docs: "Stuck migrations" section: what triggers the alert, where it shows (Sentry), and the review steps (find the rows the migration's done predicate still matches, fix or explain them).
