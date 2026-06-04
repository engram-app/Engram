# FTUX Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the first-time user experience foundation — onboarding actions table, tour-offer + create-first-vault modals, driver.js tour against a demo fixture, persistent checklist widget — so newly-signed-up users have clear next steps after the existing wizard.

**Architecture:** New `onboarding_actions` insert-only event-log table per user, queried via the existing `GET /api/onboarding/status` endpoint (single round-trip on app mount). New `POST /api/onboarding/actions` is the only write path; backend hooks fire from `Vaults.create_vault/2` and device-flow completion. Frontend mounts an `OnboardingShell` around the dashboard route — it owns three new components: a tour-offer modal, a blocking create-first-vault modal, and a bottom-right checklist widget. Tour swaps the dashboard's data layer to a static fixture via a React context, then drives the highlight steps with driver.js.

**Tech Stack:** Elixir 1.17 / Phoenix 1.8 / Ecto / PostgreSQL with RLS / React 18 / Vite / TanStack Query v5 / shadcn/ui / driver.js 1.x / Playwright

**Spec:** `docs/superpowers/specs/2026-05-30-ftux-foundation-design.md`

---

## Pre-flight (one-time)

Worktree already exists at `/home/open-claw/documents/code-projects/engram-workspace/.worktrees/ftux-foundation` on branch `feat/ftux-foundation` (tracks `origin/main`). All paths in this plan are relative to that worktree root.

- [ ] **Baseline tests are green** before starting:

  ```bash
  mix deps.get
  mix test
  cd frontend && bun install && bun test && cd ..
  ```

  Expected: zero failures. If anything red on `main`, stop and report — do NOT proceed.

---

## Phase 1 — Backend foundation

### Task 1: Migration + `onboarding_actions` table

**Files:**
- Create: `priv/repo/migrations/20260530120000_create_onboarding_actions.exs`
- Create: `test/engram/onboarding/migration_test.exs`

- [ ] **Step 1.1: Write the failing migration test**

  ```elixir
  # test/engram/onboarding/migration_test.exs
  defmodule Engram.Onboarding.MigrationTest do
    use Engram.DataCase, async: false

    alias Engram.Repo

    test "onboarding_actions table exists with expected columns + unique index" do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT column_name, data_type, is_nullable
          FROM information_schema.columns
          WHERE table_name = 'onboarding_actions'
          ORDER BY column_name
          """,
          []
        )

      cols = Map.new(rows, fn [name, type, nullable] -> {name, {type, nullable}} end)

      assert {"uuid", "NO"} = cols["id"]
      assert {"uuid", "NO"} = cols["user_id"]
      assert {_text, "NO"} = cols["action"]
      assert {"jsonb", _} = cols["metadata"]
      assert {"timestamp with time zone", "NO"} = cols["inserted_at"]

      %{rows: [[true]]} =
        Repo.query!(
          """
          SELECT EXISTS (
            SELECT 1 FROM pg_indexes
            WHERE tablename = 'onboarding_actions'
              AND indexdef LIKE '%UNIQUE%user_id%action%'
          )
          """,
          []
        )
    end
  end
  ```

- [ ] **Step 1.2: Run test to verify it fails**

  ```bash
  mix test test/engram/onboarding/migration_test.exs
  ```

  Expected: FAIL — table does not exist.

- [ ] **Step 1.3: Write the migration**

  ```elixir
  # priv/repo/migrations/20260530120000_create_onboarding_actions.exs
  defmodule Engram.Repo.Migrations.CreateOnboardingActions do
    use Ecto.Migration

    def change do
      create table(:onboarding_actions, primary_key: false) do
        add :id, :uuid, primary_key: true
        add :user_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
        add :action, :string, null: false
        add :metadata, :map, default: %{}, null: false
        add :inserted_at, :utc_datetime_usec, null: false
      end

      create unique_index(:onboarding_actions, [:user_id, :action])
      create index(:onboarding_actions, [:user_id])

      # RLS: mirror notes/vaults pattern — tenant scoped by user_id.
      execute(
        "ALTER TABLE onboarding_actions ENABLE ROW LEVEL SECURITY",
        "ALTER TABLE onboarding_actions DISABLE ROW LEVEL SECURITY"
      )

      execute(
        """
        CREATE POLICY onboarding_actions_tenant_isolation ON onboarding_actions
        USING (user_id = current_setting('app.current_tenant', true)::uuid)
        WITH CHECK (user_id = current_setting('app.current_tenant', true)::uuid)
        """,
        "DROP POLICY IF EXISTS onboarding_actions_tenant_isolation ON onboarding_actions"
      )

      # Grant runtime role same access pattern as vaults/notes.
      execute(
        "GRANT SELECT, INSERT, UPDATE, DELETE ON onboarding_actions TO engram_app",
        "REVOKE ALL ON onboarding_actions FROM engram_app"
      )
    end
  end
  ```

- [ ] **Step 1.4: Run migration + test**

  ```bash
  mix ecto.migrate
  mix test test/engram/onboarding/migration_test.exs
  ```

  Expected: migration applied, test PASS.

- [ ] **Step 1.5: Commit**

  ```bash
  git add priv/repo/migrations/20260530120000_create_onboarding_actions.exs \
          test/engram/onboarding/migration_test.exs
  git commit -m "feat(onboarding): add onboarding_actions table + RLS"
  ```

---

> **Plan correction (post-T1):** this repo uses bigserial PK + bigint user_id FK for every per-user table, NOT UUID. The literal UUID-based code in the original plan (Tasks 2-6) was wrong. Updated guidance: schema uses default integer PK + `:integer` user_id; test fixtures use `insert(:user)    # ExMachina via Engram.Factory, imported by Engram.DataCase` which returns a bigint `user.id`; never use `Ecto.UUID.generate()` for a user_id stand-in.

### Task 2: `Engram.Onboarding.Action` Ecto schema

**Files:**
- Create: `lib/engram/onboarding/action.ex`
- Create: `test/engram/onboarding/action_test.exs`

- [ ] **Step 2.1: Failing changeset test**

  ```elixir
  # test/engram/onboarding/action_test.exs
  defmodule Engram.Onboarding.ActionTest do
    use Engram.DataCase, async: true

    alias Engram.Onboarding.Action

    @user_id 12_345     # synthetic bigint; not persisted, so no FK enforcement

    test "accepts every enum value" do
      for action <- [
            "tour_offered_taken",
            "tour_offered_skipped",
            "tour_completed",
            "first_vault_created",
            "plugin_connected",
            "ai_connected"
          ] do
        assert Action.changeset(%Action{}, %{user_id: @user_id, action: action}).valid?
      end
    end

    test "rejects unknown action" do
      cs = Action.changeset(%Action{}, %{user_id: @user_id, action: "bogus"})
      refute cs.valid?
      assert {"is invalid", _} = cs.errors[:action]
    end

    test "requires user_id and action" do
      cs = Action.changeset(%Action{}, %{})
      refute cs.valid?
      assert cs.errors[:user_id]
      assert cs.errors[:action]
    end
  end
  ```

- [ ] **Step 2.2: Run, fail**

  ```bash
  mix test test/engram/onboarding/action_test.exs
  ```

  Expected: FAIL — module not loaded.

- [ ] **Step 2.3: Write schema**

  ```elixir
  # lib/engram/onboarding/action.ex
  defmodule Engram.Onboarding.Action do
    @moduledoc """
    Insert-only event log of user-completed onboarding milestones. One row
    per (user_id, action). See spec
    docs/superpowers/specs/2026-05-30-ftux-foundation-design.md for the enum
    semantics.
    """

    use Ecto.Schema
    import Ecto.Changeset

    # Default integer (bigserial) PK — matches every other per-user table.
    @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

    @actions ~w(
      tour_offered_taken
      tour_offered_skipped
      tour_completed
      first_vault_created
      plugin_connected
      ai_connected
    )

    schema "onboarding_actions" do
      field :user_id, :integer
      field :action, :string
      field :metadata, :map, default: %{}

      timestamps()
    end

    def actions, do: @actions

    def changeset(struct, attrs) do
      struct
      |> cast(attrs, [:user_id, :action, :metadata])
      |> validate_required([:user_id, :action])
      |> validate_inclusion(:action, @actions)
      |> unique_constraint([:user_id, :action], name: :onboarding_actions_user_id_action_index)
    end
  end
  ```

- [ ] **Step 2.4: Run, pass**

  ```bash
  mix test test/engram/onboarding/action_test.exs
  ```

  Expected: PASS (3 tests).

- [ ] **Step 2.5: Commit**

  ```bash
  git add lib/engram/onboarding/action.ex test/engram/onboarding/action_test.exs
  git commit -m "feat(onboarding): Action schema with enum-validated changeset"
  ```

---

### Task 3: `Engram.Onboarding` context — `record_action/2` + `list_actions/1`

The `Engram.Onboarding` module already exists (terms acceptance + `status/1`). EXTEND it — do not replace.

**Files:**
- Modify: `lib/engram/onboarding.ex`
- Modify: `test/engram/onboarding_test.exs`

- [ ] **Step 3.1: Failing tests added to existing file**

  Append to `test/engram/onboarding_test.exs`:

  ```elixir
  describe "record_action/2 + list_actions/1" do
    setup do
      user = insert(:user)    # ExMachina via Engram.Factory, imported by Engram.DataCase
      {:ok, user: user}
    end

    test "writes a row and is idempotent", %{user: user} do
      assert :ok = Onboarding.record_action(user.id, :first_vault_created)
      assert :ok = Onboarding.record_action(user.id, :first_vault_created)

      assert ["first_vault_created"] = Onboarding.list_actions(user.id)
    end

    test "list_actions/1 returns [] for unknown user" do
      assert [] = Onboarding.list_actions(0)   # bigint that no user_fixture will mint
    end

    test "lists multiple distinct actions", %{user: user} do
      :ok = Onboarding.record_action(user.id, :tour_offered_skipped)
      :ok = Onboarding.record_action(user.id, :first_vault_created)

      assert MapSet.new(["tour_offered_skipped", "first_vault_created"]) ==
               MapSet.new(Onboarding.list_actions(user.id))
    end

    test "rejects unknown action atom" do
      user_id = 12_345    # synthetic bigint
      assert {:error, %Ecto.Changeset{}} = Onboarding.record_action(user_id, :bogus)
    end
  end
  ```

  Confirm `alias Engram.Onboarding` is present in the test module's existing aliases.

- [ ] **Step 3.2: Run, fail**

  ```bash
  mix test test/engram/onboarding_test.exs --only describe:"record_action/2 + list_actions/1"
  ```

  Expected: FAIL — functions undefined.

- [ ] **Step 3.3: Add functions to context**

  Edit `lib/engram/onboarding.ex`:

  1. Add `alias Engram.Onboarding.Action` to the existing alias block.
  2. Append before the final `end`:

  ```elixir
  @doc """
  Record an onboarding milestone for `user_id`. Idempotent — re-recording the
  same action returns `:ok` with no extra row. Returns `{:error, changeset}`
  only on enum/validation failure.
  """
  def record_action(user_id, action) when is_atom(action) do
    record_action(user_id, Atom.to_string(action))
  end

  def record_action(user_id, action) when is_binary(action) do
    %Action{}
    |> Action.changeset(%{user_id: user_id, action: action})
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_id, :action],
      skip_tenant_check: true
    )
    |> case do
      {:ok, _} -> :ok
      {:error, %Ecto.Changeset{} = cs} -> {:error, cs}
    end
  end

  @doc """
  Return the set of onboarding actions recorded for `user_id` as a list of
  string action names. Empty list for unknown user.
  """
  def list_actions(user_id) when is_binary(user_id) do
    import Ecto.Query

    from(a in Action, where: a.user_id == ^user_id, select: a.action)
    |> Repo.all(skip_tenant_check: true)
  end
  ```

- [ ] **Step 3.4: Run, pass**

  ```bash
  mix test test/engram/onboarding_test.exs
  ```

  Expected: PASS (existing + 4 new).

- [ ] **Step 3.5: Commit**

  ```bash
  git add lib/engram/onboarding.ex test/engram/onboarding_test.exs
  git commit -m "feat(onboarding): record_action/2 + list_actions/1 context functions"
  ```

---

### Task 4: Extend `OnboardingController.status/2` payload + add `record/2`

**Files:**
- Modify: `lib/engram_web/controllers/onboarding_controller.ex`
- Modify: `lib/engram_web/router.ex`
- Modify: `test/engram_web/controllers/onboarding_controller_test.exs`

- [ ] **Step 4.1: Failing controller tests**

  Append to `test/engram_web/controllers/onboarding_controller_test.exs` (inside the existing module, follow its existing `setup` + auth conventions):

  ```elixir
  describe "GET /api/onboarding/status payload extensions" do
    setup [:authed_conn]   # reuse existing helper

    test "includes actions list and vault_count", %{conn: conn, user: user} do
      :ok = Engram.Onboarding.record_action(user.id, :first_vault_created)
      {:ok, _vault} = Engram.Vaults.create_vault(user, %{name: "Demo"})

      resp = conn |> get(~p"/api/onboarding/status") |> json_response(200)

      assert "first_vault_created" in resp["actions"]
      assert resp["vault_count"] == 1
    end

    test "actions defaults to [] and vault_count to 0 for new user", %{conn: conn} do
      resp = conn |> get(~p"/api/onboarding/status") |> json_response(200)
      assert resp["actions"] == []
      assert resp["vault_count"] == 0
    end
  end

  describe "POST /api/onboarding/actions" do
    setup [:authed_conn]

    test "records a valid action and is idempotent", %{conn: conn, user: user} do
      assert %{"status" => "ok"} =
               conn
               |> post(~p"/api/onboarding/actions", %{"action" => "tour_offered_skipped"})
               |> json_response(200)

      # repeat is also 200, one row
      assert %{"status" => "ok"} =
               conn
               |> post(~p"/api/onboarding/actions", %{"action" => "tour_offered_skipped"})
               |> json_response(200)

      assert ["tour_offered_skipped"] = Engram.Onboarding.list_actions(user.id)
    end

    test "rejects unknown action with 422", %{conn: conn} do
      assert %{"error" => _} =
               conn
               |> post(~p"/api/onboarding/actions", %{"action" => "bogus"})
               |> json_response(422)
    end

    test "401 when unauthenticated" do
      conn = Phoenix.ConnTest.build_conn()
      assert conn |> post(~p"/api/onboarding/actions", %{"action" => "tour_completed"})
                  |> response(401)
    end

    test "multi-tenant — cannot insert for another user", %{conn: conn, user: user} do
      other_user = insert(:user)    # ExMachina via Engram.Factory, imported by Engram.DataCase

      conn
      |> post(~p"/api/onboarding/actions", %{"action" => "tour_completed"})
      |> json_response(200)

      assert ["tour_completed"] = Engram.Onboarding.list_actions(user.id)
      assert [] = Engram.Onboarding.list_actions(other_user.id)
    end
  end
  ```

- [ ] **Step 4.2: Run, fail**

  ```bash
  mix test test/engram_web/controllers/onboarding_controller_test.exs
  ```

  Expected: FAIL — missing payload fields + missing route.

- [ ] **Step 4.3: Extend controller**

  In `lib/engram_web/controllers/onboarding_controller.ex`:

  1. Add to the `status/2` payload computation. Modify the existing `status/2`:

  ```elixir
  def status(conn, _params) do
    user = conn.assigns.current_user

    payload =
      case Onboarding.status(user) do
        %{enabled: false} = s ->
          %{enabled: false, next_step: Atom.to_string(s.next_step)}

        %{enabled: true} = s ->
          s
          |> Map.update!(:next_step, &Atom.to_string/1)
          |> reject_nil_notice()
      end
      |> Map.put(:actions, Onboarding.list_actions(user.id))
      |> Map.put(:vault_count, Engram.Vaults.count_for(user))

    json(conn, payload)
  end
  ```

  2. Add the new action handler at the bottom of the module:

  ```elixir
  def record(conn, %{"action" => action}) when is_binary(action) do
    user = conn.assigns.current_user

    case Onboarding.record_action(user.id, action) do
      :ok ->
        json(conn, %{status: "ok"})

      {:error, %Ecto.Changeset{}} ->
        conn |> put_status(422) |> json(%{error: "invalid_action"})
    end
  end

  def record(conn, _params) do
    conn |> put_status(422) |> json(%{error: "missing_action"})
  end
  ```

- [ ] **Step 4.4: Add `Vaults.count_for/1` helper**

  In `lib/engram/vaults.ex`, append:

  ```elixir
  @doc "Count of vaults owned by `user`."
  def count_for(user) do
    import Ecto.Query
    Repo.aggregate(from(v in Engram.Vaults.Vault, where: v.user_id == ^user.id), :count, :id)
  end
  ```

  (If the schema module path differs, follow the existing `Vaults` aliases.)

- [ ] **Step 4.5: Wire route**

  In `lib/engram_web/router.ex`, in the same scope/pipeline block where line 197 sits (`get "/onboarding/status"`), add directly after the existing `accept-terms` line:

  ```elixir
  post "/onboarding/actions", OnboardingController, :record
  ```

- [ ] **Step 4.6: Run, pass**

  ```bash
  mix test test/engram_web/controllers/onboarding_controller_test.exs
  ```

  Expected: PASS (existing + 6 new). If `vault_count` tests fail with stale counts, check that `Vaults.count_for/1` queries the same tenant context as the rest of the suite.

- [ ] **Step 4.7: Commit**

  ```bash
  git add lib/engram_web/controllers/onboarding_controller.ex \
          lib/engram_web/router.ex \
          lib/engram/vaults.ex \
          test/engram_web/controllers/onboarding_controller_test.exs
  git commit -m "feat(onboarding): extend /status payload + add POST /actions"
  ```

---

### Task 5: Hook `first_vault_created` into `Vaults.create_vault/2`

**Files:**
- Modify: `lib/engram/vaults.ex`
- Modify: existing vaults test file (locate via `mix test --trace test/engram/vaults_test.exs`; if absent, create `test/engram/vaults_test.exs` with the standard `Engram.DataCase`)

- [ ] **Step 5.1: Failing test**

  Append:

  ```elixir
  describe "create_vault/2 onboarding hook" do
    test "records first_vault_created on first vault" do
      user = insert(:user)    # ExMachina via Engram.Factory, imported by Engram.DataCase
      assert [] = Engram.Onboarding.list_actions(user.id)

      {:ok, _v} = Engram.Vaults.create_vault(user, %{name: "Main"})
      assert ["first_vault_created"] = Engram.Onboarding.list_actions(user.id)
    end

    test "second vault does not double-record" do
      user = insert(:user)    # ExMachina via Engram.Factory, imported by Engram.DataCase
      {:ok, _} = Engram.Vaults.create_vault(user, %{name: "Main"})
      {:ok, _} = Engram.Vaults.create_vault(user, %{name: "Second"})

      assert ["first_vault_created"] = Engram.Onboarding.list_actions(user.id)
    end
  end
  ```

- [ ] **Step 5.2: Run, fail**

  ```bash
  mix test test/engram/vaults_test.exs
  ```

  Expected: FAIL — empty action list after create.

- [ ] **Step 5.3: Hook the context**

  In `lib/engram/vaults.ex`, find the existing success branch of `create_vault/2` (the `|> case do {:ok, v} -> emit_vault_count(...) ; {:ok, decrypt_vault_if_needed(v, user)}` clause near line 50). Add the recorder call right after `emit_vault_count`. Fire-and-forget — must NOT roll back the vault on a record_action error.

  Updated block:

  ```elixir
  |> case do
    {:ok, v} ->
      emit_vault_count(user.id, :created)
      _ = Engram.Onboarding.record_action(user.id, :first_vault_created)
      {:ok, decrypt_vault_if_needed(v, user)}

    other ->
      other
  end
  ```

  Unique index makes the second-vault case a no-op DB write — no extra gating needed.

- [ ] **Step 5.4: Run, pass**

  ```bash
  mix test test/engram/vaults_test.exs
  ```

  Expected: PASS.

- [ ] **Step 5.5: Commit**

  ```bash
  git add lib/engram/vaults.ex test/engram/vaults_test.exs
  git commit -m "feat(onboarding): record first_vault_created on vault create"
  ```

---

### Task 6: Hook `plugin_connected` into device-flow completion

The plugin pairs via `Engram.Auth.DeviceFlow.exchange_device_code/1` at `lib/engram/auth/device_flow.ex:83`. The `"authorized"` branch calls `consume_and_issue_tokens(auth)`. We wrap that result: on `{:ok, _}`, record `:plugin_connected` for the preloaded `auth.user.id`. The unique index dedupes repeat pairings; failure to record must NOT block token issuance.

**Files:**
- Modify: `lib/engram/auth/device_flow.ex`
- Modify: `test/engram/auth/device_flow_test.exs` (or create if absent — use existing E2E device-flow patterns as a guide)

- [ ] **Step 6.1: Failing test**

  Append to the device-flow test (inspect the existing tests first to learn the exact `start_device_flow` + approval helper signatures — the `authorize_for_user/2` flow may differ):

  ```elixir
  describe "plugin_connected onboarding hook" do
    test "records plugin_connected on successful exchange" do
      user = insert(:user)    # ExMachina via Engram.Factory, imported by Engram.DataCase
      {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Main"})

      {:ok, %{device_code: code, user_code: user_code}} =
        Engram.Auth.DeviceFlow.start_device_flow("plugin")

      # Use whatever approval/authorization function the existing tests use —
      # signature appears in lib/engram/auth/device_flow.ex around the
      # `authorize_changeset` call (line ~73). Likely something like:
      :ok = Engram.Auth.DeviceFlow.authorize_for_user(user_code, user.id, vault.id)

      {:ok, _tokens} = Engram.Auth.DeviceFlow.exchange_device_code(code)

      assert "plugin_connected" in Engram.Onboarding.list_actions(user.id)
    end
  end
  ```

- [ ] **Step 6.2: Run, fail**

  ```bash
  mix test test/engram/auth/device_flow_test.exs
  ```

- [ ] **Step 6.3: Add hook**

  Update the `"authorized"` branch in `exchange_device_code/1` (lib/engram/auth/device_flow.ex:99) — capture the result and fire-and-forget the recorder on success:

  ```elixir
  %{status: "authorized", user: %{id: user_id}} = auth ->
    result = consume_and_issue_tokens(auth)
    case result do
      {:ok, _} -> _ = Engram.Onboarding.record_action(user_id, :plugin_connected)
      _ -> :ok
    end
    result
  ```

- [ ] **Step 6.4: Run, pass + commit**

  ```bash
  mix test test/engram/auth/device_flow_test.exs
  git add lib/engram/auth/device_flow.ex test/engram/auth/device_flow_test.exs
  git commit -m "feat(onboarding): record plugin_connected on device-flow exchange"
  ```

---

### Task 7: Backfill in a one-shot Mix release task

Migration-time backfill is risky on huge user tables and hard to test. Run the backfill via a release task triggered manually after deploy; it's idempotent (unique index swallows duplicates) so safe to re-run.

**Files:**
- Create: `lib/mix/tasks/engram.backfill_onboarding_actions.ex`
- Create: `test/mix/tasks/engram_backfill_onboarding_actions_test.exs`

- [ ] **Step 7.1: Failing test**

  ```elixir
  # test/mix/tasks/engram_backfill_onboarding_actions_test.exs
  defmodule Mix.Tasks.Engram.BackfillOnboardingActionsTest do
    use Engram.DataCase, async: false

    alias Engram.Onboarding
    alias Engram.Vaults

    test "inserts first_vault_created for every user with at least one vault" do
      user_with = insert(:user)    # ExMachina via Engram.Factory, imported by Engram.DataCase
      user_without = insert(:user)    # ExMachina via Engram.Factory, imported by Engram.DataCase
      {:ok, _} = Vaults.create_vault(user_with, %{name: "Main"})

      # Simulate a legacy user: clear the row created by the hook so the test
      # exercises pure backfill.
      Engram.Repo.delete_all(Engram.Onboarding.Action)

      Mix.Tasks.Engram.BackfillOnboardingActions.run([])

      assert ["first_vault_created"] = Onboarding.list_actions(user_with.id)
      assert [] = Onboarding.list_actions(user_without.id)
    end

    test "idempotent — second run is a no-op" do
      user = insert(:user)    # ExMachina via Engram.Factory, imported by Engram.DataCase
      {:ok, _} = Vaults.create_vault(user, %{name: "Main"})

      Mix.Tasks.Engram.BackfillOnboardingActions.run([])
      Mix.Tasks.Engram.BackfillOnboardingActions.run([])

      assert ["first_vault_created"] = Onboarding.list_actions(user.id)
    end
  end
  ```

- [ ] **Step 7.2: Run, fail**

  ```bash
  mix test test/mix/tasks/engram_backfill_onboarding_actions_test.exs
  ```

- [ ] **Step 7.3: Implement task**

  ```elixir
  # lib/mix/tasks/engram.backfill_onboarding_actions.ex
  defmodule Mix.Tasks.Engram.BackfillOnboardingActions do
    @moduledoc """
    One-shot: insert `first_vault_created` for every user with at least one
    vault. Idempotent via the unique index on (user_id, action).

    Run after deploying the onboarding_actions table:

        mix engram.backfill_onboarding_actions          # dev/test
        bin/engram eval 'Mix.Tasks.Engram.BackfillOnboardingActions.run([])'   # release
    """

    use Mix.Task

    @shortdoc "Backfill onboarding_actions for legacy users with vaults"

    @impl Mix.Task
    def run(_args) do
      Mix.Task.run("app.start")

      now = DateTime.utc_now()

      {count, _} =
        Engram.Repo.query!(
          """
          INSERT INTO onboarding_actions (id, user_id, action, metadata, inserted_at)
          SELECT gen_random_uuid(), v.user_id, 'first_vault_created', '{}'::jsonb, $1
          FROM (SELECT DISTINCT user_id FROM vaults) v
          ON CONFLICT (user_id, action) DO NOTHING
          """,
          [now]
        )
        |> Map.fetch!(:num_rows)
        |> then(&{&1, nil})

      Mix.shell().info("Backfilled #{count} onboarding_actions rows")
    end
  end
  ```

- [ ] **Step 7.4: Run, pass + commit**

  ```bash
  mix test test/mix/tasks/engram_backfill_onboarding_actions_test.exs
  git add lib/mix/tasks/engram.backfill_onboarding_actions.ex \
          test/mix/tasks/engram_backfill_onboarding_actions_test.exs
  git commit -m "feat(onboarding): one-shot backfill Mix task"
  ```

**Backend Phase 1 sanity:** `mix test` — full suite green before moving on.

---

## Phase 2 — Frontend foundation

All paths in this phase are relative to `frontend/` unless otherwise noted.

### Task 8: Install driver.js + scaffold onboarding dir

- [ ] **Step 8.1**

  ```bash
  cd frontend && bun add driver.js
  ```

  Expected: `driver.js` in `package.json` dependencies. Confirm with `grep driver.js package.json`.

- [ ] **Step 8.2: Scaffold dir + import driver.js CSS once at app entry**

  In `frontend/src/main.tsx`, add near the other CSS imports:

  ```ts
  import 'driver.js/dist/driver.css'
  ```

- [ ] **Step 8.3: Commit**

  ```bash
  git add frontend/package.json frontend/bun.lock frontend/src/main.tsx
  git commit -m "chore(onboarding): add driver.js + global CSS"
  ```

---

### Task 9: `useOnboardingActions` hook (record mutation + derived flags)

Reuses the existing `useOnboardingStatus()` query — adds a `recordOnboardingAction` mutation that invalidates the status query on success.

**Files:**
- Modify: `frontend/src/api/queries.ts` (where `useOnboardingStatus` lives — add a `useRecordOnboardingAction` hook next to it)
- Create: `frontend/src/onboarding/use-onboarding-actions.ts`
- Create: `frontend/src/onboarding/use-onboarding-actions.test.tsx`

- [ ] **Step 9.1: Add the mutation hook to `queries.ts`**

  Append below `useOnboardingStatus`:

  ```ts
  export type OnboardingAction =
    | 'tour_offered_taken'
    | 'tour_offered_skipped'
    | 'tour_completed'
    | 'first_vault_created'
    | 'plugin_connected'
    | 'ai_connected'

  export function useRecordOnboardingAction() {
    const qc = useQueryClient()
    return useMutation({
      mutationFn: async (action: OnboardingAction) => {
        const res = await apiFetch('/api/onboarding/actions', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action }),
        })
        if (!res.ok) throw new Error(`record action failed: ${res.status}`)
      },
      onSuccess: () => qc.invalidateQueries({ queryKey: ['onboarding-status'] }),
      retry: 3,
    })
  }
  ```

  (Match the file's existing import style for `useMutation`, `useQueryClient`, `apiFetch`, etc. — read the top of the file before adding.)

  Also extend the `useOnboardingStatus` response type to include the new fields:

  ```ts
  // Wherever the OnboardingStatus type is defined:
  export interface OnboardingStatus {
    // ... existing fields ...
    actions: OnboardingAction[]
    vault_count: number
  }
  ```

- [ ] **Step 9.2: Wrapper hook with derived booleans**

  ```ts
  // frontend/src/onboarding/use-onboarding-actions.ts
  import { useOnboardingStatus, useRecordOnboardingAction, type OnboardingAction } from '../api/queries'

  export function useOnboardingActions() {
    const { data, isLoading } = useOnboardingStatus()
    const { mutate, mutateAsync } = useRecordOnboardingAction()

    const actions = new Set<OnboardingAction>(data?.actions ?? [])

    return {
      isLoading,
      vaultCount: data?.vault_count ?? 0,
      has: (a: OnboardingAction) => actions.has(a),
      hasTourDecision: actions.has('tour_offered_skipped') || actions.has('tour_completed'),
      record: mutate,
      recordAsync: mutateAsync,
    }
  }
  ```

- [ ] **Step 9.3: Unit test**

  ```tsx
  // frontend/src/onboarding/use-onboarding-actions.test.tsx
  import { renderHook } from '@testing-library/react'
  import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
  import { useOnboardingActions } from './use-onboarding-actions'

  jest.mock('../api/queries', () => ({
    useOnboardingStatus: () => ({
      data: {
        enabled: true,
        next_step: 'done',
        actions: ['first_vault_created'],
        vault_count: 1,
      },
      isLoading: false,
    }),
    useRecordOnboardingAction: () => ({ mutate: jest.fn(), mutateAsync: jest.fn() }),
  }))

  const wrap = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={new QueryClient()}>{children}</QueryClientProvider>
  )

  test('has + derived flags reflect actions list', () => {
    const { result } = renderHook(() => useOnboardingActions(), { wrapper: wrap })
    expect(result.current.has('first_vault_created')).toBe(true)
    expect(result.current.has('plugin_connected')).toBe(false)
    expect(result.current.hasTourDecision).toBe(false)
    expect(result.current.vaultCount).toBe(1)
  })
  ```

- [ ] **Step 9.4: Run, pass, commit**

  ```bash
  cd frontend && bun test src/onboarding/use-onboarding-actions.test.tsx
  git add frontend/src/api/queries.ts frontend/src/onboarding/use-onboarding-actions.ts \
          frontend/src/onboarding/use-onboarding-actions.test.tsx
  git commit -m "feat(onboarding): useOnboardingActions hook + mutation"
  ```

---

### Task 10: `DemoVaultProvider` context + fixture loader

The provider exposes `{ active, vault, folders, notes }` via React context. When `active`, dashboard data hooks read from this context instead of API queries. Fixture is lazy-fetched from `/demo-vault.json` ONLY when activation requested.

**Files:**
- Create: `frontend/public/demo-vault.json`
- Create: `frontend/src/onboarding/tour/demo-vault-provider.tsx`
- Create: `frontend/src/onboarding/tour/demo-vault-provider.test.tsx`

- [ ] **Step 10.1: Write the fixture**

  ```json
  // frontend/public/demo-vault.json
  {
    "vault": { "id": "demo-vault", "name": "Demo Vault" },
    "folders": [
      { "id": "f-welcome",   "name": "Welcome",   "path": "Welcome" },
      { "id": "f-examples",  "name": "Examples",  "path": "Examples" },
      { "id": "f-reference", "name": "Reference", "path": "Reference" }
    ],
    "notes": [
      {
        "id": "n-1", "folder_id": "f-welcome", "path": "Welcome/Start here.md",
        "title": "Start here",
        "content": "# Welcome to Engram\n\nThis is a demo vault. Click around — nothing here is saved.\n\nSee [[Markdown features]] for what the editor supports."
      },
      {
        "id": "n-2", "folder_id": "f-welcome", "path": "Welcome/Markdown features.md",
        "title": "Markdown features",
        "content": "# Markdown features\n\n> [!tip]\n> Callouts work.\n\n```python\nprint('code blocks too')\n```\n\nInline math: $E = mc^2$"
      },
      {
        "id": "n-3", "folder_id": "f-examples", "path": "Examples/Meeting notes.md",
        "title": "Meeting notes",
        "content": "# Meeting notes — 2026-05-30\n\n- Topic 1\n- Topic 2\n\nLinks back to [[Start here]]."
      },
      {
        "id": "n-4", "folder_id": "f-examples", "path": "Examples/Reading list.md",
        "title": "Reading list",
        "content": "# Reading list\n\n- A book\n- Another book\n- A third book"
      },
      {
        "id": "n-5", "folder_id": "f-reference", "path": "Reference/Cheatsheet.md",
        "title": "Cheatsheet",
        "content": "# Cheatsheet\n\n| Key | Action |\n|-----|--------|\n| ⌘K | Search |\n| ⌘N | New note |"
      },
      {
        "id": "n-6", "folder_id": "f-reference", "path": "Reference/Diagram.md",
        "title": "Diagram",
        "content": "# Diagram\n\n```mermaid\ngraph LR\n  Note --> Vault --> Engram\n```"
      }
    ]
  }
  ```

- [ ] **Step 10.2: Failing provider test**

  ```tsx
  // frontend/src/onboarding/tour/demo-vault-provider.test.tsx
  import { render, screen, act } from '@testing-library/react'
  import { DemoVaultProvider, useDemoVault } from './demo-vault-provider'

  const Probe = () => {
    const ctx = useDemoVault()
    return <div data-testid="probe">{ctx.active ? ctx.vault?.name : 'inactive'}</div>
  }

  beforeEach(() => {
    global.fetch = jest.fn(() =>
      Promise.resolve({
        ok: true,
        json: () =>
          Promise.resolve({
            vault: { id: 'demo-vault', name: 'Demo Vault' },
            folders: [],
            notes: [],
          }),
      }),
    ) as unknown as typeof fetch
  })

  test('inactive by default, active after activate()', async () => {
    let activate!: () => Promise<void>
    function Capture() {
      const ctx = useDemoVault()
      activate = ctx.activate
      return null
    }
    render(
      <DemoVaultProvider>
        <Probe />
        <Capture />
      </DemoVaultProvider>,
    )

    expect(screen.getByTestId('probe').textContent).toBe('inactive')
    await act(async () => { await activate() })
    expect(screen.getByTestId('probe').textContent).toBe('Demo Vault')
  })
  ```

- [ ] **Step 10.3: Provider implementation**

  ```tsx
  // frontend/src/onboarding/tour/demo-vault-provider.tsx
  import { createContext, useCallback, useContext, useMemo, useState, type ReactNode } from 'react'

  export interface DemoNote { id: string; folder_id: string; path: string; title: string; content: string }
  export interface DemoFolder { id: string; name: string; path: string }
  export interface DemoVault { id: string; name: string }

  interface DemoVaultData {
    vault: DemoVault
    folders: DemoFolder[]
    notes: DemoNote[]
  }

  interface DemoVaultCtx {
    active: boolean
    vault: DemoVault | null
    folders: DemoFolder[]
    notes: DemoNote[]
    activate: () => Promise<void>
    deactivate: () => void
  }

  const Ctx = createContext<DemoVaultCtx | null>(null)

  export function DemoVaultProvider({ children }: { children: ReactNode }) {
    const [data, setData] = useState<DemoVaultData | null>(null)

    const activate = useCallback(async () => {
      const res = await fetch('/demo-vault.json')
      if (!res.ok) throw new Error('demo fixture missing')
      const json = (await res.json()) as DemoVaultData
      setData(json)
    }, [])

    const deactivate = useCallback(() => setData(null), [])

    const value = useMemo<DemoVaultCtx>(
      () => ({
        active: data !== null,
        vault: data?.vault ?? null,
        folders: data?.folders ?? [],
        notes: data?.notes ?? [],
        activate,
        deactivate,
      }),
      [data, activate, deactivate],
    )

    return <Ctx.Provider value={value}>{children}</Ctx.Provider>
  }

  export function useDemoVault(): DemoVaultCtx {
    const v = useContext(Ctx)
    if (!v) throw new Error('useDemoVault must be used inside DemoVaultProvider')
    return v
  }
  ```

- [ ] **Step 10.4: Wire dashboard query hooks to consult DemoVault**

  In `frontend/src/api/queries.ts` (or wherever `useVaults`, `useFolders`, `useNotesInFolder` live), wrap the hooks:

  ```ts
  // Pseudocode — adapt to actual hook signatures:
  export function useVaults() {
    const demo = useDemoVault()        // safe: provider mounted at OnboardingShell
    const realQuery = useQuery({ queryKey: ['vaults'], queryFn: fetchVaults, enabled: !demo.active })
    if (demo.active) return { data: [demo.vault], isLoading: false }
    return realQuery
  }
  ```

  Do this for the three data hooks the dashboard relies on: vaults, folder tree, and notes list. The provider is the single switch — when `active`, every data hook short-circuits to the fixture.

  **Important:** if any data hook lives outside the OnboardingShell tree (e.g. settings pages), it must NOT see the demo. Either move the provider lower in the tree, or have those out-of-tree hooks fall through gracefully when `useDemoVault` throws (use `useContext(Ctx)` directly, treat null as "no demo").

- [ ] **Step 10.5: Run, pass, commit**

  ```bash
  cd frontend && bun test src/onboarding/tour/demo-vault-provider.test.tsx
  git add frontend/public/demo-vault.json \
          frontend/src/onboarding/tour/demo-vault-provider.tsx \
          frontend/src/onboarding/tour/demo-vault-provider.test.tsx \
          frontend/src/api/queries.ts
  git commit -m "feat(onboarding): demo vault provider + fixture"
  ```

---

### Task 11: Tour steps + driver.js controller

**Files:**
- Create: `frontend/src/onboarding/tour/steps.ts`
- Create: `frontend/src/onboarding/tour/controller.tsx`
- Create: `frontend/src/onboarding/tour/controller.test.tsx`

- [ ] **Step 11.1: Step definitions**

  ```ts
  // frontend/src/onboarding/tour/steps.ts
  import type { DriveStep } from 'driver.js'

  export const tourSteps: DriveStep[] = [
    {
      element: '[data-tour="sidebar-vaults"]',
      popover: {
        title: 'Your vaults',
        description:
          'A vault is a collection of notes. You can have many. Right now you’re looking at a demo.',
        side: 'right',
        align: 'start',
      },
    },
    {
      element: '[data-tour="folder-tree"]',
      popover: {
        title: 'Folders mirror your filesystem',
        description:
          'The folder structure here matches what lives in your Obsidian vault on disk.',
        side: 'right',
      },
    },
    {
      element: '[data-tour="note-viewer"]',
      popover: {
        title: 'Read and edit anywhere',
        description:
          'Click any note to view it. Full Obsidian-style markdown — wikilinks, callouts, math, mermaid.',
        side: 'left',
      },
    },
    {
      element: '[data-tour="search"]',
      popover: {
        title: 'Search everything',
        description: 'Full-text + semantic search across every note in every vault.',
        side: 'bottom',
      },
    },
    {
      element: '[data-tour="settings-link"]',
      popover: {
        title: 'Settings live here',
        description:
          'Manage vaults, billing, API keys, and (soon) connect Obsidian + AI tools.',
        side: 'right',
      },
    },
    {
      element: '[data-tour="dashboard-root"]',
      popover: {
        title: 'You’re ready',
        description: 'Now let’s create your real first vault.',
        side: 'over',
        doneBtnText: 'Create my vault',
      },
    },
  ]
  ```

- [ ] **Step 11.2: Controller failing test**

  ```tsx
  // frontend/src/onboarding/tour/controller.test.tsx
  import { render } from '@testing-library/react'
  import { TourController } from './controller'

  const driveMock = { drive: jest.fn(), destroy: jest.fn() }
  jest.mock('driver.js', () => ({ driver: jest.fn(() => driveMock) }))

  test('starts driver.js on mount when active=true', () => {
    render(<TourController active onExit={() => {}} reachedEnd={false} setReachedEnd={() => {}} />)
    expect(driveMock.drive).toHaveBeenCalled()
  })

  test('does nothing when active=false', () => {
    render(<TourController active={false} onExit={() => {}} reachedEnd={false} setReachedEnd={() => {}} />)
    expect(driveMock.drive).not.toHaveBeenCalled()
  })
  ```

- [ ] **Step 11.3: Controller implementation**

  ```tsx
  // frontend/src/onboarding/tour/controller.tsx
  import { useEffect, useRef } from 'react'
  import { driver, type Driver } from 'driver.js'
  import { tourSteps } from './steps'

  interface Props {
    active: boolean
    onExit: (reachedEnd: boolean) => void
    reachedEnd: boolean
    setReachedEnd: (v: boolean) => void
  }

  export function TourController({ active, onExit, setReachedEnd }: Props) {
    const drvRef = useRef<Driver | null>(null)
    const reachedRef = useRef(false)

    useEffect(() => {
      if (!active) return

      const drv = driver({
        showProgress: true,
        steps: tourSteps,
        onHighlighted: (_el, _step, opts) => {
          if (opts.state.activeIndex === tourSteps.length - 1) {
            reachedRef.current = true
            setReachedEnd(true)
          }
        },
        onDestroyed: () => {
          onExit(reachedRef.current)
        },
      })

      drvRef.current = drv
      drv.drive()

      return () => {
        drv.destroy()
      }
    }, [active, onExit, setReachedEnd])

    return null
  }
  ```

- [ ] **Step 11.4: Run, pass, commit**

  ```bash
  cd frontend && bun test src/onboarding/tour/controller.test.tsx
  git add frontend/src/onboarding/tour/steps.ts \
          frontend/src/onboarding/tour/controller.tsx \
          frontend/src/onboarding/tour/controller.test.tsx
  git commit -m "feat(onboarding): tour steps + driver.js controller"
  ```

---

### Task 12: `TourOfferModal`

**Files:**
- Create: `frontend/src/onboarding/tour-offer-modal.tsx`
- Create: `frontend/src/onboarding/tour-offer-modal.test.tsx`

- [ ] **Step 12.1: Test**

  ```tsx
  // frontend/src/onboarding/tour-offer-modal.test.tsx
  import { render, screen, fireEvent } from '@testing-library/react'
  import { TourOfferModal } from './tour-offer-modal'

  test('renders headline + two buttons; click handlers wired', () => {
    const onTake = jest.fn()
    const onSkip = jest.fn()
    render(<TourOfferModal onTake={onTake} onSkip={onSkip} />)

    expect(screen.getByRole('heading', { name: /quick tour/i })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /take.*tour/i }))
    expect(onTake).toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: /skip/i }))
    expect(onSkip).toHaveBeenCalled()
  })
  ```

- [ ] **Step 12.2: Implementation**

  ```tsx
  // frontend/src/onboarding/tour-offer-modal.tsx
  import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '../components/ui/dialog'
  import { Button } from '../components/ui/button'

  interface Props { onTake: () => void; onSkip: () => void }

  export function TourOfferModal({ onTake, onSkip }: Props) {
    return (
      <Dialog open onOpenChange={(o) => { if (!o) onSkip() }}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>Want a quick tour?</DialogTitle>
            <DialogDescription>
              Two minutes. We’ll walk through your vault, the editor, search, and where settings live.
            </DialogDescription>
          </DialogHeader>
          <div className="flex justify-end gap-2 pt-2">
            <Button variant="ghost" onClick={onSkip}>Skip</Button>
            <Button onClick={onTake}>Take the tour</Button>
          </div>
        </DialogContent>
      </Dialog>
    )
  }
  ```

- [ ] **Step 12.3: Run, pass, commit**

  ```bash
  cd frontend && bun test src/onboarding/tour-offer-modal.test.tsx
  git add frontend/src/onboarding/tour-offer-modal.tsx frontend/src/onboarding/tour-offer-modal.test.tsx
  git commit -m "feat(onboarding): tour offer modal"
  ```

---

### Task 13: Extract `VaultCreateForm` + `CreateFirstVaultModal`

**Files:**
- Modify: `frontend/src/settings/vaults-page.tsx` (extract inline form)
- Create: `frontend/src/components/vault-create-form.tsx`
- Create: `frontend/src/onboarding/create-first-vault-modal.tsx`
- Create: `frontend/src/onboarding/create-first-vault-modal.test.tsx`

- [ ] **Step 13.1: Extract reusable form**

  Read `frontend/src/settings/vaults-page.tsx` lines 1-64 (the inline create form). Extract into `frontend/src/components/vault-create-form.tsx`:

  ```tsx
  // frontend/src/components/vault-create-form.tsx
  import { useState } from 'react'
  import { useCreateVault } from '../api/queries'    // existing mutation
  import { Button } from './ui/button'
  import { Input } from './ui/input'

  interface Props {
    onCreated?: (vaultId: string) => void
    submitLabel?: string
    autoFocus?: boolean
  }

  export function VaultCreateForm({ onCreated, submitLabel = 'Create', autoFocus = false }: Props) {
    const [name, setName] = useState('')
    const { mutate, isPending, error } = useCreateVault()

    const submit = (e: React.FormEvent) => {
      e.preventDefault()
      if (!name.trim()) return
      mutate({ name: name.trim() }, { onSuccess: (v) => onCreated?.(v.id) })
    }

    return (
      <form onSubmit={submit} className="flex flex-col gap-3">
        <Input
          autoFocus={autoFocus}
          placeholder="My notes"
          value={name}
          onChange={(e) => setName(e.target.value)}
          disabled={isPending}
        />
        {error && <p className="text-sm text-destructive">{error.message}</p>}
        <Button type="submit" disabled={isPending || !name.trim()}>
          {isPending ? 'Creating…' : submitLabel}
        </Button>
      </form>
    )
  }
  ```

  Then replace the inline form in `vaults-page.tsx` with `<VaultCreateForm onCreated={...} />`. Verify the settings page still works manually.

- [ ] **Step 13.2: Modal test**

  ```tsx
  // frontend/src/onboarding/create-first-vault-modal.test.tsx
  import { render, screen, fireEvent } from '@testing-library/react'
  import { CreateFirstVaultModal } from './create-first-vault-modal'

  jest.mock('../components/vault-create-form', () => ({
    VaultCreateForm: ({ onCreated }: { onCreated: (id: string) => void }) => (
      <button onClick={() => onCreated('v-1')}>fake-create</button>
    ),
  }))

  test('renders heading; ESC + click-outside do nothing; onCreated bubbles', () => {
    const onCreated = jest.fn()
    render(<CreateFirstVaultModal onCreated={onCreated} />)

    expect(screen.getByRole('heading', { name: /first vault/i })).toBeInTheDocument()

    // ESC should not close — Radix dispatches keydown; simulate and assert still mounted
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(screen.getByRole('heading', { name: /first vault/i })).toBeInTheDocument()

    fireEvent.click(screen.getByText('fake-create'))
    expect(onCreated).toHaveBeenCalledWith('v-1')
  })
  ```

- [ ] **Step 13.3: Modal implementation**

  ```tsx
  // frontend/src/onboarding/create-first-vault-modal.tsx
  import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '../components/ui/dialog'
  import { VaultCreateForm } from '../components/vault-create-form'

  interface Props { onCreated: (vaultId: string) => void }

  export function CreateFirstVaultModal({ onCreated }: Props) {
    return (
      <Dialog open>
        <DialogContent
          className="sm:max-w-md"
          // Block: hide close button (CSS) + intercept dismiss attempts.
          onEscapeKeyDown={(e) => e.preventDefault()}
          onPointerDownOutside={(e) => e.preventDefault()}
          onInteractOutside={(e) => e.preventDefault()}
          hideClose
        >
          <DialogHeader>
            <DialogTitle>Create your first vault</DialogTitle>
            <DialogDescription>
              A vault holds your notes. You can rename it or add more later.
            </DialogDescription>
          </DialogHeader>
          <VaultCreateForm autoFocus submitLabel="Create vault" onCreated={onCreated} />
        </DialogContent>
      </Dialog>
    )
  }
  ```

  If `DialogContent` does not support a `hideClose` prop in the local shadcn fork, replicate the prop by extending `DialogContent` in `frontend/src/components/ui/dialog.tsx` to skip rendering the close `<DialogPrimitive.Close>` when `hideClose` is true. Same change unblocks the test's assertion that ESC is ignored.

- [ ] **Step 13.4: Run, pass, commit**

  ```bash
  cd frontend && bun test src/onboarding/create-first-vault-modal.test.tsx \
                          src/settings/vaults-page.test.tsx
  git add frontend/src/components/vault-create-form.tsx \
          frontend/src/settings/vaults-page.tsx \
          frontend/src/components/ui/dialog.tsx \
          frontend/src/onboarding/create-first-vault-modal.tsx \
          frontend/src/onboarding/create-first-vault-modal.test.tsx
  git commit -m "feat(onboarding): create-first-vault modal + extract VaultCreateForm"
  ```

---

### Task 14: `ChecklistWidget`

**Files:**
- Create: `frontend/src/onboarding/checklist-widget.tsx`
- Create: `frontend/src/onboarding/checklist-widget.test.tsx`

- [ ] **Step 14.1: Test**

  ```tsx
  // frontend/src/onboarding/checklist-widget.test.tsx
  import { render, screen, fireEvent } from '@testing-library/react'
  import { ChecklistWidget } from './checklist-widget'

  jest.mock('./use-onboarding-actions', () => ({
    useOnboardingActions: () => ({
      isLoading: false,
      vaultCount: 1,
      has: (a: string) => a === 'first_vault_created',
      hasTourDecision: true,
      record: jest.fn(),
      recordAsync: jest.fn(),
    }),
  }))

  test('shows checked vault item, unchecked plugin item, collapses to FAB on dismiss', () => {
    render(<ChecklistWidget onStartTour={() => {}} />)

    expect(screen.getByText(/create.*first vault/i)).toBeInTheDocument()
    expect(screen.getByText(/install.*plugin/i)).toBeInTheDocument()

    fireEvent.click(screen.getByLabelText(/dismiss/i))
    expect(screen.queryByText(/create.*first vault/i)).not.toBeInTheDocument()
    expect(screen.getByLabelText(/open onboarding/i)).toBeInTheDocument()
  })
  ```

- [ ] **Step 14.2: Implementation**

  ```tsx
  // frontend/src/onboarding/checklist-widget.tsx
  import { useState } from 'react'
  import { useOnboardingActions } from './use-onboarding-actions'
  import { Card, CardContent, CardHeader, CardTitle } from '../components/ui/card'
  import { Button } from '../components/ui/button'

  interface Props { onStartTour: () => void }

  interface Item { key: string; label: string; done: boolean; cta?: () => void; ctaLabel?: string; comingSoon?: boolean }

  export function ChecklistWidget({ onStartTour }: Props) {
    const [collapsed, setCollapsed] = useState(false)
    const ob = useOnboardingActions()

    if (ob.isLoading) return null

    const items: Item[] = [
      { key: 'vault', label: 'Create your first vault', done: ob.has('first_vault_created') },
      {
        key: 'plugin',
        label: 'Install the Obsidian plugin',
        done: ob.has('plugin_connected'),
        ctaLabel: 'Get plugin',
        cta: () => window.open('https://app.engram.page/device-link', '_self'),
      },
      ...(ob.has('tour_offered_skipped') && !ob.has('tour_completed')
        ? [{ key: 'tour', label: 'Take the tour', done: false, ctaLabel: 'Start', cta: onStartTour } as Item]
        : []),
      { key: 'ai', label: 'Connect AI (coming soon)', done: false, comingSoon: true },
    ]

    const allDone = items.every((i) => i.done || i.comingSoon)
    if (allDone) return null

    if (collapsed) {
      return (
        <button
          aria-label="Open onboarding checklist"
          className="fixed bottom-4 right-4 rounded-full shadow-lg bg-primary text-primary-foreground h-12 w-12"
          onClick={() => setCollapsed(false)}
        >
          ✓
        </button>
      )
    }

    return (
      <Card className="fixed bottom-4 right-4 w-80 shadow-lg">
        <CardHeader className="flex flex-row justify-between items-center">
          <CardTitle className="text-base">Get started</CardTitle>
          <button aria-label="Dismiss checklist" onClick={() => setCollapsed(true)}>×</button>
        </CardHeader>
        <CardContent className="flex flex-col gap-2">
          {items.map((i) => (
            <div key={i.key} className="flex items-center justify-between text-sm">
              <span className={`flex items-center gap-2 ${i.comingSoon ? 'opacity-50' : ''}`}>
                <span aria-hidden>{i.done ? '✅' : '☐'}</span>
                {i.label}
              </span>
              {i.cta && !i.done && (
                <Button size="sm" variant="outline" onClick={i.cta}>{i.ctaLabel}</Button>
              )}
            </div>
          ))}
        </CardContent>
      </Card>
    )
  }
  ```

- [ ] **Step 14.3: Run, pass, commit**

  ```bash
  cd frontend && bun test src/onboarding/checklist-widget.test.tsx
  git add frontend/src/onboarding/checklist-widget.tsx frontend/src/onboarding/checklist-widget.test.tsx
  git commit -m "feat(onboarding): checklist widget"
  ```

---

### Task 15: `OnboardingShell` orchestrator + router wiring + `data-tour` anchors

**Files:**
- Create: `frontend/src/onboarding/onboarding-shell.tsx`
- Create: `frontend/src/onboarding/onboarding-shell.test.tsx`
- Modify: `frontend/src/router.tsx`
- Modify: `frontend/src/viewer/dashboard.tsx` + sidebar/folder/search components (data-tour attrs)

- [ ] **Step 15.1: Shell test**

  ```tsx
  // frontend/src/onboarding/onboarding-shell.test.tsx
  import { render, screen, fireEvent, act } from '@testing-library/react'
  import { OnboardingShell } from './onboarding-shell'

  const mockRecord = jest.fn(() => Promise.resolve())
  jest.mock('./use-onboarding-actions', () => ({
    useOnboardingActions: () => ({
      isLoading: false,
      vaultCount: 0,
      has: () => false,
      hasTourDecision: false,
      record: mockRecord,
      recordAsync: mockRecord,
    }),
  }))

  beforeEach(() => { mockRecord.mockClear() })

  test('opens tour-offer modal, then vault modal after skip', async () => {
    render(<OnboardingShell><div>dashboard</div></OnboardingShell>)
    expect(screen.getByRole('heading', { name: /quick tour/i })).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: /skip/i }))
    await act(async () => {})
    expect(mockRecord).toHaveBeenCalledWith('tour_offered_skipped')
    expect(screen.getByRole('heading', { name: /first vault/i })).toBeInTheDocument()
  })
  ```

- [ ] **Step 15.2: Shell implementation**

  ```tsx
  // frontend/src/onboarding/onboarding-shell.tsx
  import { useState, type ReactNode } from 'react'
  import { useOnboardingActions } from './use-onboarding-actions'
  import { TourOfferModal } from './tour-offer-modal'
  import { CreateFirstVaultModal } from './create-first-vault-modal'
  import { ChecklistWidget } from './checklist-widget'
  import { DemoVaultProvider, useDemoVault } from './tour/demo-vault-provider'
  import { TourController } from './tour/controller'

  function ShellInner({ children }: { children: ReactNode }) {
    const ob = useOnboardingActions()
    const demo = useDemoVault()

    const [tourOfferHandled, setTourOfferHandled] = useState(false)
    const [tourActive, setTourActive] = useState(false)
    const [tourReachedEnd, setTourReachedEnd] = useState(false)
    const [vaultModalHandled, setVaultModalHandled] = useState(false)

    if (ob.isLoading) return <>{children}</>

    const isMobile = typeof window !== 'undefined' && window.innerWidth < 768
    const showTourOffer = !tourOfferHandled && !ob.hasTourDecision && !isMobile && !tourActive
    const showVaultModal = !vaultModalHandled && ob.vaultCount === 0 && !tourActive

    const startTour = async () => {
      ob.record('tour_offered_taken')
      await demo.activate()
      setTourOfferHandled(true)
      setTourActive(true)
    }

    const skipTour = () => {
      ob.record('tour_offered_skipped')
      setTourOfferHandled(true)
    }

    const onTourExit = (reachedEnd: boolean) => {
      if (reachedEnd) ob.record('tour_completed')
      setTourActive(false)
      demo.deactivate()
    }

    return (
      <>
        {children}
        {showTourOffer && <TourOfferModal onTake={startTour} onSkip={skipTour} />}
        {tourActive && (
          <TourController
            active={tourActive}
            reachedEnd={tourReachedEnd}
            setReachedEnd={setTourReachedEnd}
            onExit={onTourExit}
          />
        )}
        {showVaultModal && !showTourOffer && (
          <CreateFirstVaultModal onCreated={() => setVaultModalHandled(true)} />
        )}
        <ChecklistWidget onStartTour={startTour} />
      </>
    )
  }

  export function OnboardingShell({ children }: { children: ReactNode }) {
    return (
      <DemoVaultProvider>
        <ShellInner>{children}</ShellInner>
      </DemoVaultProvider>
    )
  }
  ```

- [ ] **Step 15.3: Wire into router**

  Edit `frontend/src/router.tsx`: wrap the Dashboard route element in `<OnboardingShell>`. Exact spot depends on the existing JSX shape — find the route whose `path: "/"` renders `Dashboard` (or wherever the post-onboarding home lives) and wrap:

  ```tsx
  import { OnboardingShell } from './onboarding/onboarding-shell'
  // ...
  {
    path: '/',
    element: (
      <OnboardingGate>
        <OnboardingShell>
          <Dashboard />
        </OnboardingShell>
      </OnboardingGate>
    ),
  }
  ```

  (Match the actual nesting — `OnboardingGate` wraps via `<Outlet />`; if so, mount `OnboardingShell` on the dashboard route's `element` not as a layout outlet.)

- [ ] **Step 15.4: Add `data-tour` anchors**

  Find each component and add `data-tour="..."`:

  | Anchor | Likely file |
  |---|---|
  | `data-tour="sidebar-vaults"` | `frontend/src/viewer/sidebar.tsx` (the VaultSwitcher block) |
  | `data-tour="folder-tree"` | `frontend/src/viewer/folder-tree.tsx` (root element) |
  | `data-tour="note-viewer"` | `frontend/src/viewer/dashboard.tsx` (main column container) |
  | `data-tour="search"` | header search input/button (`frontend/src/viewer/header.tsx` or similar) |
  | `data-tour="settings-link"` | settings nav link (likely in sidebar) |
  | `data-tour="dashboard-root"` | outermost `<div>` of `Dashboard` |

  Drop on the outermost element of each region so driver.js highlights the whole block. Anchors should also live on the equivalent fixture-rendered components — since real + fixture share the same component tree, the same attrs apply automatically.

- [ ] **Step 15.5: Run frontend test suite, pass**

  ```bash
  cd frontend && bun test src/onboarding/
  ```

- [ ] **Step 15.6: Commit**

  ```bash
  git add frontend/src/onboarding/onboarding-shell.tsx \
          frontend/src/onboarding/onboarding-shell.test.tsx \
          frontend/src/router.tsx \
          frontend/src/viewer/dashboard.tsx frontend/src/viewer/sidebar.tsx \
          frontend/src/viewer/folder-tree.tsx frontend/src/viewer/header.tsx
  git commit -m "feat(onboarding): orchestrator shell + data-tour anchors + router wire"
  ```

---

## Phase 3 — E2E

Tests live in `frontend/e2e/specs/onboarding-ftux.spec.ts`. Existing helpers in `frontend/e2e/helpers/` provide Clerk test signup + cleanup. Read `frontend/e2e/specs/<existing>.spec.ts` for harness patterns first.

### Task 16: E2E spec file scaffold + Test 1 (happy path with tour)

**Files:**
- Create: `frontend/e2e/specs/onboarding-ftux.spec.ts`

- [ ] **Step 16.1: Scaffold**

  ```ts
  // frontend/e2e/specs/onboarding-ftux.spec.ts
  import { test, expect } from '@playwright/test'
  import { signUpFreshClerkUser, completeOnboardingWizard } from '../helpers/auth'

  test.describe('FTUX', () => {
    test('happy path with tour completes through vault creation', async ({ page }) => {
      await signUpFreshClerkUser(page)
      await completeOnboardingWizard(page)   // agreement + billing trial

      await expect(page.getByRole('heading', { name: /quick tour/i })).toBeVisible()
      await page.getByRole('button', { name: /take the tour/i }).click()

      // Demo fixture rendered
      await expect(page.getByText('Start here')).toBeVisible()

      // Step through driver.js popovers
      for (let i = 0; i < 5; i++) {
        await page.locator('.driver-popover-next-btn').click()
      }
      // Final step CTA
      await page.getByRole('button', { name: /create my vault/i }).click()

      // Create-vault modal
      await expect(page.getByRole('heading', { name: /first vault/i })).toBeVisible()
      await page.getByPlaceholder('My notes').fill('My Vault')
      await page.getByRole('button', { name: /create vault/i }).click()

      // Checklist reflects state
      await expect(page.getByText(/create your first vault/i)).toBeVisible()
      await expect(page.locator('text=✅').first()).toBeVisible()
    })
  })
  ```

  If `signUpFreshClerkUser` / `completeOnboardingWizard` helpers don't exist, port the equivalent steps from the existing `agreement-page.spec.ts` (or wherever Clerk-aware tests live) into a new `frontend/e2e/helpers/auth.ts`.

- [ ] **Step 16.2: Run + commit (test should pass against local SaaS stack)**

  ```bash
  # From workspace root:
  make saas-dev    # if not already running
  cd backend/frontend && bun playwright test e2e/specs/onboarding-ftux.spec.ts
  git add frontend/e2e/specs/onboarding-ftux.spec.ts frontend/e2e/helpers/auth.ts
  git commit -m "test(e2e): FTUX happy path"
  ```

---

### Task 17: Remaining E2E tests

Add to the same spec file. Commit after each green test (six commits, one per test) so failures localize easily.

- [ ] **Step 17.1: Skip tour path**

  ```ts
  test('skip tour still shows create-vault modal', async ({ page }) => {
    await signUpFreshClerkUser(page)
    await completeOnboardingWizard(page)

    await page.getByRole('button', { name: /^skip$/i }).click()
    await expect(page.getByRole('heading', { name: /first vault/i })).toBeVisible()

    await page.getByPlaceholder('My notes').fill('My Vault')
    await page.getByRole('button', { name: /create vault/i }).click()

    // Checklist shows "Take the tour" item still actionable
    await expect(page.getByRole('button', { name: /^start$/i })).toBeVisible()
  })
  ```

  Commit: `test(e2e): FTUX skip-tour path`

- [ ] **Step 17.2: Vault modal is blocking**

  ```ts
  test('vault modal cannot be dismissed by ESC, click-outside, or close button', async ({ page }) => {
    await signUpFreshClerkUser(page)
    await completeOnboardingWizard(page)
    await page.getByRole('button', { name: /^skip$/i }).click()

    const heading = page.getByRole('heading', { name: /first vault/i })
    await expect(heading).toBeVisible()

    await page.keyboard.press('Escape')
    await expect(heading).toBeVisible()

    await page.mouse.click(10, 10)   // outside the dialog
    await expect(heading).toBeVisible()

    // No close button visible
    await expect(page.getByRole('button', { name: /close/i })).toHaveCount(0)
  })
  ```

  Commit: `test(e2e): FTUX vault modal is blocking`

- [ ] **Step 17.3: Persistence across reload**

  ```ts
  test('completed flow does not re-fire modals after reload', async ({ page }) => {
    await signUpFreshClerkUser(page)
    await completeOnboardingWizard(page)
    await page.getByRole('button', { name: /^skip$/i }).click()
    await page.getByPlaceholder('My notes').fill('My Vault')
    await page.getByRole('button', { name: /create vault/i }).click()

    await page.reload()
    await expect(page.getByRole('heading', { name: /quick tour/i })).toHaveCount(0)
    await expect(page.getByRole('heading', { name: /first vault/i })).toHaveCount(0)
  })
  ```

  Commit: `test(e2e): FTUX persistence across reload`

- [ ] **Step 17.4: Plugin connection action updates checklist**

  ```ts
  test('completing device-link flow ticks the plugin checklist item', async ({ page, request }) => {
    const { user } = await signUpFreshClerkUser(page)
    await completeOnboardingWizard(page)
    await page.getByRole('button', { name: /^skip$/i }).click()
    await page.getByPlaceholder('My notes').fill('My Vault')
    await page.getByRole('button', { name: /create vault/i }).click()

    // Drive the device flow via API (or open /device-link in a second context).
    // Pseudo: helper that simulates plugin pairing for `user`.
    await simulatePluginPair(request, user)

    await expect(page.getByText(/install.*plugin/i)
      .locator('xpath=ancestor::*[contains(@class, "flex")]')
      .getByText('✅')).toBeVisible({ timeout: 5000 })
  })
  ```

  (Implement `simulatePluginPair` in `frontend/e2e/helpers/device-flow.ts` — hit `POST /api/auth/device/start`, then approve via API key auth path used by the existing device-flow test.)

  Commit: `test(e2e): FTUX plugin checklist tick on device pair`

- [ ] **Step 17.5: Backfilled user (no first-vault prompt)**

  ```ts
  test('user with existing vault sees no vault modal', async ({ page }) => {
    const { user } = await signUpFreshClerkUser(page)
    await completeOnboardingWizard(page)
    // Programmatically create a vault before landing on dashboard:
    await page.request.post('/api/vaults', { data: { name: 'Existing' } })
    await page.goto('/')

    await expect(page.getByRole('heading', { name: /first vault/i })).toHaveCount(0)
  })
  ```

  Commit: `test(e2e): FTUX no prompt when vault exists`

- [ ] **Step 17.6: Mobile viewport behavior**

  ```ts
  test('mobile viewport: checklist collapses to FAB, tour offer suppressed', async ({ browser }) => {
    const context = await browser.newContext({ viewport: { width: 375, height: 667 } })
    const page = await context.newPage()
    await signUpFreshClerkUser(page)
    await completeOnboardingWizard(page)

    // Tour offer suppressed
    await expect(page.getByRole('heading', { name: /quick tour/i })).toHaveCount(0)

    // Vault modal still appears
    await expect(page.getByRole('heading', { name: /first vault/i })).toBeVisible()

    await page.getByPlaceholder('My notes').fill('Mobile Vault')
    await page.getByRole('button', { name: /create vault/i }).click()

    // Checklist appears as FAB
    await expect(page.getByLabel(/open onboarding/i)).toBeVisible()
  })
  ```

  Commit: `test(e2e): FTUX mobile viewport`

- [ ] **Step 17.7: Run full E2E suite**

  ```bash
  cd backend/frontend && bun playwright test e2e/specs/onboarding-ftux.spec.ts
  ```

  Expected: 7 specs PASS.

---

## Verification

End-to-end before opening PR:

- [ ] `mix test` — full backend suite green (including new tests)
- [ ] `mix credo --strict` — no new findings
- [ ] `mix sobelow --exit low` — no new findings
- [ ] `cd frontend && bun test` — full frontend Jest suite green
- [ ] `cd frontend && bun run build` — clean production build
- [ ] `make saas-dev` from workspace root + walk the flow on a fresh signup via laptop-browser CDP tunnel (`docs/context/local-browser-cdp-tunnel.md`)
- [ ] `bun playwright test e2e/specs/onboarding-ftux.spec.ts` — all 7 E2E specs green
- [ ] Chrome DevTools mobile-mode (375×667) spot-check
- [ ] Reload dashboard at every stage — assert modal state matches persisted actions
- [ ] After deploy: run `bin/engram eval 'Mix.Tasks.Engram.BackfillOnboardingActions.run([])'` on each environment (staging first, then prod)

## Commit cadence + PR

- Each task lands as ≥1 commit using conventional-commit prefixes (`feat(onboarding):`, `test(e2e):`, `chore(onboarding):`)
- After Task 7 (backend phase done), push branch + open draft PR. Continue committing on the PR through Phase 2/3.
- PR title: `feat(onboarding): first-time user experience foundation`
- PR body links the spec at `docs/superpowers/specs/2026-05-30-ftux-foundation-design.md`

## Open follow-ups (file as GH issues at PR time)

- Add connections-page tour step when that page lands (one-line addition to `tour/steps.ts`)
- Wire `ai_connected` recording from real AI-connect flow
- Mobile tour (currently suppressed <768px)
- PostHog events under `ftux.*` namespace for funnel analysis
- Marketing copy review pass on modal headlines
