# Signup Wizard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a forced three-phase onboarding flow (account creation → TOS acceptance → paid subscription) that gates the application via a backend `RequireOnboarding` plug and a frontend `OnboardingGate` redirect. Wizard is fully disabled in self-host mode (`PADDLE_API_KEY` unset).

**Architecture:** New `user_agreements` table (versioned, per-user, RLS-isolated) records TOS acceptances. A single `RequireOnboarding` plug runs on the vault-scoped pipeline and returns `403 {error: "onboarding_required", missing: [...]}` when the user hasn't completed both gates. The plug short-circuits in self-host mode (`billing_enabled=false`). Frontend `OnboardingGate` wraps the dashboard route tree, reads `GET /api/onboarding/status`, and redirects to `/onboard/agreement` or `/onboard/billing`. Existing `/api/billing/*` endpoints power the payment step.

**Tech Stack:** Elixir/Phoenix 1.8, Ecto SQL, PostgreSQL with RLS, React + TypeScript, TanStack Query, react-router, Vitest + RTL, pytest for E2E.

**Spec:** `docs/superpowers/specs/2026-05-15-signup-wizard-design.md`

---

## File map

**Backend — create:**
- `priv/repo/migrations/<timestamp>_create_user_agreements.exs`
- `lib/engram/onboarding.ex` — context module (`status/1`, `accept_terms/3`)
- `lib/engram/onboarding/agreement.ex` — Ecto schema
- `lib/engram_web/plugs/require_onboarding.ex`
- `lib/engram_web/controllers/onboarding_controller.ex`
- `test/engram/onboarding_test.exs`
- `test/engram_web/plugs/require_onboarding_test.exs`
- `test/engram_web/controllers/onboarding_controller_test.exs`
- `test/support/factories/agreement_factory.ex` *(or inline in `test/support/factory.ex`)*

**Backend — modify:**
- `lib/engram/repo.ex` — add `:user_agreements` to `@tenant_tables`
- `lib/engram_web/router.ex` — add endpoints + plug + SPA whitelist
- `config/runtime.exs` — add `:billing_enabled` and `:current_tos_version`
- `config/test.exs` — set `:billing_enabled` and `:current_tos_version` for test runs

**Frontend — create:**
- `frontend/src/onboarding/onboarding-gate.tsx`
- `frontend/src/onboarding/onboard-layout.tsx`
- `frontend/src/onboarding/onboard-redirect.tsx`
- `frontend/src/onboarding/agreement-page.tsx`
- `frontend/src/onboarding/onboard-billing-page.tsx`
- `frontend/src/legal/terms-of-service.tsx` — JSX TOS body + version export
- `frontend/src/onboarding/onboarding-gate.test.tsx`
- `frontend/src/onboarding/agreement-page.test.tsx`

**Frontend — modify:**
- `frontend/src/api/queries.ts` — add `useOnboardingStatus`, `useAcceptTerms`, types
- `frontend/src/router.tsx` — add `/onboard/*` routes, wrap dashboard tree in `OnboardingGate`
- `frontend/src/routes.ts` — add `ONBOARD` constants (if pattern there)

**E2E — create:**
- `e2e/tests/test_onboarding.py`

---

## Task 1: Migration — create `user_agreements` table with RLS

**Files:**
- Create: `priv/repo/migrations/<timestamp>_create_user_agreements.exs`

- [ ] **Step 1: Generate the migration file**

```bash
mix ecto.gen.migration create_user_agreements
```

Note the generated filename (e.g. `priv/repo/migrations/20260515123045_create_user_agreements.exs`).

- [ ] **Step 2: Write the migration**

Replace the generated file's content with:

```elixir
defmodule Engram.Repo.Migrations.CreateUserAgreements do
  use Ecto.Migration

  def up do
    create table(:user_agreements) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :document, :text, null: false
      add :version, :text, null: false
      add :accepted_at, :utc_datetime, null: false, default: fragment("now()")
      add :ip_address, :inet
      add :user_agent, :text
    end

    create index(:user_agreements, [:user_id, :document])
    create index(:user_agreements, [:user_id, :document, :accepted_at])

    execute "ALTER TABLE user_agreements ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE user_agreements FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation_user_agreements ON user_agreements
      USING (user_id::text = current_setting('app.current_tenant', true))
      WITH CHECK (user_id::text = current_setting('app.current_tenant', true))
    """

    # Grant access to the runtime role (RLS-subject)
    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON user_agreements TO engram_app"
    execute "GRANT USAGE, SELECT ON SEQUENCE user_agreements_id_seq TO engram_app"
  end

  def down do
    execute "DROP POLICY IF EXISTS tenant_isolation_user_agreements ON user_agreements"
    execute "ALTER TABLE user_agreements DISABLE ROW LEVEL SECURITY"
    drop table(:user_agreements)
  end
end
```

- [ ] **Step 3: Run the migration**

```bash
mix ecto.migrate
```

Expected output: `[info] == Running ... CreateUserAgreements.up/0 forward` followed by the executed SQL and `[info] == Migrated ... in 0.0s`.

- [ ] **Step 4: Verify the table + policy exist**

```bash
mix run -e 'IO.inspect(Engram.Repo.query!("SELECT polname FROM pg_policy WHERE polrelid = '"'"'user_agreements'"'"'::regclass").rows)'
```

Expected output includes `["tenant_isolation_user_agreements"]`.

- [ ] **Step 5: Commit**

```bash
git add priv/repo/migrations/
git commit -m "feat(onboarding): create user_agreements table with RLS"
```

---

## Task 2: Add `user_agreements` to `Engram.Repo`'s tenant tables

This wires `prepare_query/3` so that any query against `user_agreements` without `with_tenant/2` raises `Engram.TenantError`. The matching test verifies enforcement.

**Files:**
- Modify: `lib/engram/repo.ex` (the `@tenant_tables` attribute)
- Create: `test/engram/repo_user_agreements_tenant_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/engram/repo_user_agreements_tenant_test.exs`:

```elixir
defmodule Engram.RepoUserAgreementsTenantTest do
  use Engram.DataCase, async: false

  test "querying user_agreements without with_tenant raises TenantError" do
    assert_raise Engram.TenantError, fn ->
      Engram.Repo.all(Engram.Onboarding.Agreement)
    end
  end

  test "querying user_agreements inside with_tenant succeeds" do
    user = insert(:user)

    result =
      Engram.Repo.with_tenant(user.id, fn ->
        Engram.Repo.all(Engram.Onboarding.Agreement)
      end)

    assert result == {:ok, []}
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
mix test test/engram/repo_user_agreements_tenant_test.exs
```

Expected: FAIL — either `Engram.Onboarding.Agreement` not found, or no TenantError raised because `:user_agreements` isn't in the tenant list yet.

- [ ] **Step 3: Modify the @tenant_tables attribute**

Edit `lib/engram/repo.ex`. Change:

```elixir
  @tenant_tables ~w(notes chunks attachments api_keys vaults)a
```

to:

```elixir
  @tenant_tables ~w(notes chunks attachments api_keys vaults user_agreements)a
```

- [ ] **Step 4: Skip the test temporarily**

The test still won't pass because `Engram.Onboarding.Agreement` doesn't exist yet. Skip it for now:

```elixir
  @tag :skip
  test "querying user_agreements without with_tenant raises TenantError" do
```

Run again to confirm only the skip remains:

```bash
mix test test/engram/repo_user_agreements_tenant_test.exs
```

Expected: PASS (both tests skipped, or one runs and passes after Task 3 defines the schema).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/repo.ex test/engram/repo_user_agreements_tenant_test.exs
git commit -m "feat(onboarding): add user_agreements to tenant-scoped tables"
```

The skip will be removed in Task 3.

---

## Task 3: Ecto schema `Engram.Onboarding.Agreement`

**Files:**
- Create: `lib/engram/onboarding/agreement.ex`
- Modify: `test/support/factory.ex` (add agreement factory)
- Modify: `test/engram/repo_user_agreements_tenant_test.exs` (remove `:skip` tag)

- [ ] **Step 1: Write the schema**

Create `lib/engram/onboarding/agreement.ex`:

```elixir
defmodule Engram.Onboarding.Agreement do
  @moduledoc """
  Records a user's acceptance of a versioned legal document (Terms of
  Service, Privacy Policy, etc.). One row per user per accepted version.
  Tenant-scoped via RLS — must be queried inside `Repo.with_tenant/2`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "user_agreements" do
    field :document, :string
    field :version, :string
    field :accepted_at, :utc_datetime
    field :ip_address, EctoNetwork.INET
    field :user_agent, :string

    belongs_to :user, Engram.Accounts.User
  end

  def changeset(agreement, attrs) do
    agreement
    |> cast(attrs, [:user_id, :document, :version, :accepted_at, :ip_address, :user_agent])
    |> validate_required([:user_id, :document, :version, :accepted_at])
  end
end
```

**Note on `EctoNetwork.INET`:** Ecto's built-in types don't include `inet`. Check `mix.exs` deps — if `ecto_network` is not already present, switch the field declaration to `field :ip_address, :string` and the controller will store the rendered IP string (`Tuple.to_list(ip) |> Enum.join(".")` or similar). To avoid adding a dep, use `:string` and convert in the context. Change the migration to `add :ip_address, :text` if you make this choice — but `:inet` is a Postgres native type, so leaving it as `:inet` in the DB and writing/reading strings via Ecto works because Postgres casts strings to inet on input. Recommend: keep DB column as `:inet`, declare schema field as `:string`, convert tuple to dotted-quad string in the context module.

If you take the `:string` route, simplify the schema field:

```elixir
    field :ip_address, :string
```

- [ ] **Step 2: Add a factory**

Edit `test/support/factory.ex`. Add to the existing factory module (typically at the bottom, before `end`):

```elixir
  def agreement_factory do
    %Engram.Onboarding.Agreement{
      user: build(:user),
      document: "terms_of_service",
      version: "2026-05-15",
      accepted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      ip_address: nil,
      user_agent: nil
    }
  end
```

- [ ] **Step 3: Remove the `:skip` from Task 2's test**

Edit `test/engram/repo_user_agreements_tenant_test.exs` — remove the `@tag :skip` line.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
mix test test/engram/repo_user_agreements_tenant_test.exs
```

Expected: PASS — both tenant-enforcement tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/onboarding/ test/support/factory.ex test/engram/repo_user_agreements_tenant_test.exs
git commit -m "feat(onboarding): add Agreement schema and factory"
```

---

## Task 4: `Engram.Onboarding.accept_terms/3`

**Files:**
- Create: `lib/engram/onboarding.ex`
- Create: `test/engram/onboarding_test.exs`

- [ ] **Step 1: Write failing tests for `accept_terms/3`**

Create `test/engram/onboarding_test.exs`:

```elixir
defmodule Engram.OnboardingTest do
  use Engram.DataCase, async: true

  alias Engram.Onboarding
  alias Engram.Onboarding.Agreement

  describe "accept_terms/3" do
    test "inserts an agreement row for the user and version" do
      user = insert(:user)

      {:ok, %Agreement{} = agreement} =
        Onboarding.accept_terms(user, "2026-05-15", %{
          ip_address: "192.168.1.1",
          user_agent: "Mozilla/5.0"
        })

      assert agreement.user_id == user.id
      assert agreement.document == "terms_of_service"
      assert agreement.version == "2026-05-15"
      assert agreement.ip_address == "192.168.1.1"
      assert agreement.user_agent == "Mozilla/5.0"
      assert agreement.accepted_at != nil
    end

    test "allows the same user to accept multiple versions" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-01-01", %{})
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      rows =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.all(Agreement)
        end)
        |> elem(1)

      assert length(rows) == 2
    end

    test "rejects empty version" do
      user = insert(:user)
      assert {:error, %Ecto.Changeset{}} = Onboarding.accept_terms(user, "", %{})
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/engram/onboarding_test.exs
```

Expected: FAIL with `Engram.Onboarding.accept_terms/3 is undefined`.

- [ ] **Step 3: Implement `Engram.Onboarding.accept_terms/3`**

Create `lib/engram/onboarding.ex`:

```elixir
defmodule Engram.Onboarding do
  @moduledoc """
  Onboarding context: TOS acceptance tracking and wizard-state computation.

  Wizard is fully disabled when `Application.get_env(:engram, :billing_enabled)`
  is false (self-host mode). In that mode `status/1` reports `next_step: :done`
  unconditionally and `RequireOnboarding` is a no-op.
  """

  alias Engram.Billing
  alias Engram.Onboarding.Agreement
  alias Engram.Repo

  @terms_document "terms_of_service"

  @doc """
  Record that `user` accepted document version `version`. `meta` may carry
  `:ip_address` (string) and `:user_agent` (string) for audit purposes.
  Returns `{:ok, %Agreement{}}` or `{:error, %Ecto.Changeset{}}`.
  """
  def accept_terms(user, version, meta) when is_binary(version) do
    attrs = %{
      user_id: user.id,
      document: @terms_document,
      version: version,
      accepted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      ip_address: Map.get(meta, :ip_address),
      user_agent: Map.get(meta, :user_agent)
    }

    %Agreement{}
    |> Agreement.changeset(attrs)
    |> Repo.insert(skip_tenant_check: true)
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
mix test test/engram/onboarding_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/onboarding.ex test/engram/onboarding_test.exs
git commit -m "feat(onboarding): add accept_terms context function"
```

---

## Task 5: `Engram.Onboarding.status/1`

**Files:**
- Modify: `lib/engram/onboarding.ex`
- Modify: `test/engram/onboarding_test.exs`

- [ ] **Step 1: Write failing tests for `status/1`**

Append to `test/engram/onboarding_test.exs` inside the module:

```elixir
  describe "status/1 when billing is disabled (self-host)" do
    setup do
      Application.put_env(:engram, :billing_enabled, false)
      Application.put_env(:engram, :current_tos_version, "2026-05-15")
      on_exit(fn -> Application.put_env(:engram, :billing_enabled, true) end)
      :ok
    end

    test "returns enabled=false and next_step=done regardless of state" do
      user = insert(:user)
      assert %{enabled: false, next_step: :done} = Onboarding.status(user)
    end
  end

  describe "status/1 when billing is enabled" do
    setup do
      Application.put_env(:engram, :billing_enabled, true)
      Application.put_env(:engram, :current_tos_version, "2026-05-15")
      :ok
    end

    test "next_step=agreement when user has no agreement and no subscription" do
      user = insert(:user)

      assert %{
               enabled: true,
               terms_ok: false,
               subscription_ok: false,
               current_tos_version: "2026-05-15",
               next_step: :agreement
             } = Onboarding.status(user)
    end

    test "next_step=billing when terms accepted but no subscription" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})

      assert %{terms_ok: true, subscription_ok: false, next_step: :billing} =
               Onboarding.status(user)
    end

    test "next_step=done when terms accepted and active subscription exists" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "trialing")

      assert %{terms_ok: true, subscription_ok: true, next_step: :done} =
               Onboarding.status(user)
    end

    test "next_step=agreement when accepted version is older than current_tos_version" do
      user = insert(:user)
      {:ok, _} = Onboarding.accept_terms(user, "2025-01-01", %{})
      insert(:subscription, user: user, status: "active")

      assert %{terms_ok: false, subscription_ok: true, next_step: :agreement} =
               Onboarding.status(user)
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/engram/onboarding_test.exs
```

Expected: FAIL with `Engram.Onboarding.status/1 is undefined`.

- [ ] **Step 3: Implement `status/1`**

Append to `lib/engram/onboarding.ex` (inside the module, before the final `end`):

```elixir
  @doc """
  Compute the onboarding state for a user. Returns a map with:

    * `:enabled` — true when billing (and therefore the wizard) is active
    * `:terms_ok` — current TOS version accepted
    * `:subscription_ok` — user has trialing/active/past_due subscription
    * `:current_tos_version` — string from config
    * `:next_step` — one of `:agreement | :billing | :done`

  When `billing_enabled` is false (self-host), returns `{enabled: false,
  next_step: :done}` immediately so callers can skip all gates.
  """
  def status(user) do
    if Application.get_env(:engram, :billing_enabled, false) do
      current_version = Application.get_env(:engram, :current_tos_version)
      terms_ok = terms_accepted?(user, current_version)
      subscription_ok = Billing.active?(user)
      next = next_step(terms_ok, subscription_ok)

      %{
        enabled: true,
        terms_ok: terms_ok,
        subscription_ok: subscription_ok,
        current_tos_version: current_version,
        next_step: next
      }
    else
      %{enabled: false, next_step: :done}
    end
  end

  defp terms_accepted?(user, current_version) do
    import Ecto.Query

    latest =
      from(a in Agreement,
        where: a.user_id == ^user.id and a.document == ^@terms_document,
        order_by: [desc: a.accepted_at],
        limit: 1,
        select: a.version
      )
      |> Repo.one(skip_tenant_check: true)

    case latest do
      nil -> false
      accepted -> accepted >= current_version
    end
  end

  defp next_step(false, _), do: :agreement
  defp next_step(true, false), do: :billing
  defp next_step(true, true), do: :done
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
mix test test/engram/onboarding_test.exs
```

Expected: PASS — all `status/1` tests green.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/onboarding.ex test/engram/onboarding_test.exs
git commit -m "feat(onboarding): add status/1 wizard-state computation"
```

---

## Task 6: `RequireOnboarding` plug

**Files:**
- Create: `lib/engram_web/plugs/require_onboarding.ex`
- Create: `test/engram_web/plugs/require_onboarding_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/engram_web/plugs/require_onboarding_test.exs`:

```elixir
defmodule EngramWeb.Plugs.RequireOnboardingTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Onboarding
  alias EngramWeb.Plugs.RequireOnboarding

  setup do
    Application.put_env(:engram, :billing_enabled, true)
    Application.put_env(:engram, :current_tos_version, "2026-05-15")
    on_exit(fn -> Application.put_env(:engram, :billing_enabled, true) end)
    :ok
  end

  test "passes through when billing is disabled (self-host)", %{conn: conn} do
    Application.put_env(:engram, :billing_enabled, false)
    user = insert(:user)
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    refute conn.halted
  end

  test "halts 403 with missing=[terms,subscription] when both gates fail", %{conn: conn} do
    user = insert(:user)
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["error"] == "onboarding_required"
    assert Enum.sort(body["missing"]) == ["subscription", "terms"]
  end

  test "halts 403 with missing=[subscription] when only subscription is missing", %{conn: conn} do
    user = insert(:user)
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["missing"] == ["subscription"]
  end

  test "halts 403 with missing=[terms] when only terms is missing", %{conn: conn} do
    user = insert(:user)
    insert(:subscription, user: user, status: "trialing")
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    assert conn.halted
    assert conn.status == 403
    body = Phoenix.ConnTest.json_response(conn, 403)
    assert body["missing"] == ["terms"]
  end

  test "passes through when both gates are satisfied", %{conn: conn} do
    user = insert(:user)
    {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
    insert(:subscription, user: user, status: "trialing")
    conn = conn |> assign(:current_user, user) |> RequireOnboarding.call([])
    refute conn.halted
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/engram_web/plugs/require_onboarding_test.exs
```

Expected: FAIL — `EngramWeb.Plugs.RequireOnboarding` undefined.

- [ ] **Step 3: Implement the plug**

Create `lib/engram_web/plugs/require_onboarding.ex`:

```elixir
defmodule EngramWeb.Plugs.RequireOnboarding do
  @moduledoc """
  Halts authenticated requests with 403 `{error: "onboarding_required",
  missing: [...]}` when the user has not completed the signup wizard
  (TOS acceptance + active subscription). Bypassed in self-host mode
  (`billing_enabled=false`).

  Must run after `EngramWeb.Plugs.Auth` (needs `conn.assigns.current_user`)
  and after `EngramWeb.Plugs.RotationLockCheck`. May run before or after
  `VaultPlug`; in this codebase it runs immediately before VaultPlug so
  no vault is resolved for users we'll 403.
  """

  import Plug.Conn

  alias Engram.Onboarding

  def init(opts), do: opts

  def call(conn, _opts) do
    user = conn.assigns[:current_user]

    case Onboarding.status(user) do
      %{enabled: false} ->
        conn

      %{next_step: :done} ->
        conn

      %{terms_ok: terms_ok, subscription_ok: sub_ok} ->
        missing =
          []
          |> then(&if terms_ok, do: &1, else: ["terms" | &1])
          |> then(&if sub_ok, do: &1, else: ["subscription" | &1])
          |> Enum.sort()

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, Jason.encode!(%{error: "onboarding_required", missing: missing}))
        |> halt()
    end
  end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
mix test test/engram_web/plugs/require_onboarding_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/plugs/require_onboarding.ex test/engram_web/plugs/require_onboarding_test.exs
git commit -m "feat(onboarding): add RequireOnboarding plug"
```

---

## Task 7: Onboarding controller — status + accept-terms endpoints

**Files:**
- Create: `lib/engram_web/controllers/onboarding_controller.ex`
- Create: `test/engram_web/controllers/onboarding_controller_test.exs`

- [ ] **Step 1: Write failing tests**

Create `test/engram_web/controllers/onboarding_controller_test.exs`:

```elixir
defmodule EngramWeb.OnboardingControllerTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts

  setup %{conn: conn} do
    Application.put_env(:engram, :billing_enabled, true)
    Application.put_env(:engram, :current_tos_version, "2026-05-15")
    user = insert(:user)
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    conn = put_req_header(conn, "authorization", "Bearer #{raw_key}")
    {:ok, conn: conn, user: user}
  end

  describe "GET /api/onboarding/status" do
    test "returns next_step=agreement for a new user", %{conn: conn} do
      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      assert body["enabled"] == true
      assert body["terms_ok"] == false
      assert body["subscription_ok"] == false
      assert body["next_step"] == "agreement"
      assert body["current_tos_version"] == "2026-05-15"
    end

    test "returns next_step=done for fully onboarded user", %{conn: conn, user: user} do
      {:ok, _} = Engram.Onboarding.accept_terms(user, "2026-05-15", %{})
      insert(:subscription, user: user, status: "trialing")

      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      assert body["next_step"] == "done"
    end

    test "returns enabled=false in self-host mode", %{conn: conn} do
      Application.put_env(:engram, :billing_enabled, false)
      conn = get(conn, "/api/onboarding/status")
      body = json_response(conn, 200)
      assert body["enabled"] == false
      assert body["next_step"] == "done"
    end
  end

  describe "POST /api/onboarding/accept-terms" do
    test "201 records acceptance with ip + user_agent", %{conn: conn, user: user} do
      conn =
        conn
        |> put_req_header("user-agent", "Mozilla/5.0 (test)")
        |> post("/api/onboarding/accept-terms", %{"version" => "2026-05-15"})

      body = json_response(conn, 201)
      assert body["version"] == "2026-05-15"
      assert body["accepted_at"] != nil

      # Verify the row was actually inserted
      [agreement] =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.all(Engram.Onboarding.Agreement)
        end)
        |> elem(1)

      assert agreement.user_id == user.id
      assert agreement.version == "2026-05-15"
      assert agreement.user_agent == "Mozilla/5.0 (test)"
    end

    test "422 when version does not match current_tos_version", %{conn: conn} do
      conn = post(conn, "/api/onboarding/accept-terms", %{"version" => "2099-01-01"})
      body = json_response(conn, 422)
      assert body["error"] == "version_mismatch"
    end
  end
end
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
mix test test/engram_web/controllers/onboarding_controller_test.exs
```

Expected: FAIL — controller not yet defined; routes will 404.

- [ ] **Step 3: Implement the controller**

Create `lib/engram_web/controllers/onboarding_controller.ex`:

```elixir
defmodule EngramWeb.OnboardingController do
  use EngramWeb, :controller

  alias Engram.Onboarding

  def status(conn, _params) do
    user = conn.assigns.current_user
    state = Onboarding.status(user)

    payload =
      case state do
        %{enabled: false} ->
          %{enabled: false, next_step: "done"}

        %{
          enabled: true,
          terms_ok: terms_ok,
          subscription_ok: sub_ok,
          current_tos_version: version,
          next_step: next
        } ->
          %{
            enabled: true,
            terms_ok: terms_ok,
            subscription_ok: sub_ok,
            current_tos_version: version,
            next_step: Atom.to_string(next)
          }
      end

    json(conn, payload)
  end

  def accept_terms(conn, %{"version" => version}) do
    user = conn.assigns.current_user
    current_version = Application.get_env(:engram, :current_tos_version)

    if version == current_version do
      meta = %{
        ip_address: format_ip(conn.remote_ip),
        user_agent: get_user_agent(conn)
      }

      case Onboarding.accept_terms(user, version, meta) do
        {:ok, agreement} ->
          conn
          |> put_status(:created)
          |> json(%{version: agreement.version, accepted_at: agreement.accepted_at})

        {:error, _changeset} ->
          conn |> put_status(422) |> json(%{error: "invalid"})
      end
    else
      conn |> put_status(422) |> json(%{error: "version_mismatch"})
    end
  end

  def accept_terms(conn, _params) do
    conn |> put_status(422) |> json(%{error: "missing_version"})
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip(tuple) when tuple_size(tuple) == 8, do: tuple |> :inet.ntoa() |> to_string()
  defp format_ip(_), do: nil

  defp get_user_agent(conn) do
    case Plug.Conn.get_req_header(conn, "user-agent") do
      [ua | _] -> ua
      _ -> nil
    end
  end
end
```

- [ ] **Step 4: Run the tests to confirm they still fail on the route**

```bash
mix test test/engram_web/controllers/onboarding_controller_test.exs
```

Expected: FAIL — still 404 because the router doesn't have these routes yet. Wired in Task 8.

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/controllers/onboarding_controller.ex test/engram_web/controllers/onboarding_controller_test.exs
git commit -m "feat(onboarding): add OnboardingController (status + accept-terms)"
```

---

## Task 8: Wire router — endpoints, plug, SPA whitelist

**Files:**
- Modify: `lib/engram_web/router.ex`

- [ ] **Step 1: Add the two onboarding endpoints under the user-scoped pipeline**

Edit `lib/engram_web/router.ex`. In the scope at lines ~124-163 (`scope "/api", EngramWeb do` with `pipe_through [:api, EngramWeb.Plugs.Auth, EngramWeb.Plugs.RotationLockCheck]`), after the billing routes (currently `get "/billing/portal", BillingController, :customer_portal`) and before the `post "/oauth/authorize/consent"` line, add:

```elixir
    # Onboarding wizard — status + TOS acceptance. Exempt from
    # RequireOnboarding (the plug is only on the vault-scoped pipeline)
    # so the wizard can actually function before completion.
    get "/onboarding/status", OnboardingController, :status
    post "/onboarding/accept-terms", OnboardingController, :accept_terms
```

- [ ] **Step 2: Add `RequireOnboarding` to the vault-scoped pipeline**

In the scope at lines ~175-225 (`# Vault-scoped authenticated endpoints (VaultPlug resolves current_vault)`), change the `pipe_through` from:

```elixir
    pipe_through [
      :api,
      EngramWeb.Plugs.Auth,
      EngramWeb.Plugs.RotationLockCheck,
      EngramWeb.Plugs.VaultPlug
    ]
```

to:

```elixir
    pipe_through [
      :api,
      EngramWeb.Plugs.Auth,
      EngramWeb.Plugs.RotationLockCheck,
      EngramWeb.Plugs.RequireOnboarding,
      EngramWeb.Plugs.VaultPlug
    ]
```

Also remove (or rewrite) the stale comment immediately above the pipeline:

```elixir
    # NOTE: EngramWeb.Plugs.RequireActiveSubscription will be added here when
    # billing goes live (tracked in docs/superpowers/plans/2026-04-06-security-hardening.md).
```

Replace with:

```elixir
    # RequireOnboarding gates vault access on TOS + active subscription
    # (skipped entirely in self-host mode; see lib/engram/onboarding.ex).
```

- [ ] **Step 3: Whitelist `/onboard` SPA routes**

In the SPA scope (lines ~232-246), add after the existing `/billing` line:

```elixir
    get "/onboard", SpaController, :index
    get "/onboard/*path", SpaController, :index
```

- [ ] **Step 4: Run Task 7's controller tests to confirm they now pass**

```bash
mix test test/engram_web/controllers/onboarding_controller_test.exs
```

Expected: PASS — all controller tests green now that routes exist.

- [ ] **Step 5: Write an integration test confirming the gate halts vault routes**

Create `test/engram_web/onboarding_gate_integration_test.exs`:

```elixir
defmodule EngramWeb.OnboardingGateIntegrationTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts

  setup %{conn: conn} do
    Application.put_env(:engram, :billing_enabled, true)
    Application.put_env(:engram, :current_tos_version, "2026-05-15")
    user = insert(:user)
    _vault = insert(:vault, user: user, is_default: true)
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    conn = put_req_header(conn, "authorization", "Bearer #{raw_key}")
    {:ok, conn: conn, user: user}
  end

  test "GET /api/folders/list returns 403 onboarding_required for new user", %{conn: conn} do
    conn = get(conn, "/api/folders/list")
    body = json_response(conn, 403)
    assert body["error"] == "onboarding_required"
    assert "subscription" in body["missing"]
    assert "terms" in body["missing"]
  end

  test "GET /api/folders/list returns 200 after onboarding completes", %{conn: conn, user: user} do
    {:ok, _} = Engram.Onboarding.accept_terms(user, "2026-05-15", %{})
    insert(:subscription, user: user, status: "trialing")

    conn = get(conn, "/api/folders/list")
    assert conn.status == 200
  end

  test "GET /api/folders/list returns 200 in self-host mode", %{conn: conn} do
    Application.put_env(:engram, :billing_enabled, false)
    conn = get(conn, "/api/folders/list")
    assert conn.status == 200
  end
end
```

- [ ] **Step 6: Run the integration test**

```bash
mix test test/engram_web/onboarding_gate_integration_test.exs
```

Expected: PASS.

- [ ] **Step 7: Run the full backend suite to confirm no regression**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add lib/engram_web/router.ex test/engram_web/onboarding_gate_integration_test.exs
git commit -m "feat(onboarding): wire router endpoints, gate plug, SPA whitelist"
```

---

## Task 9: Runtime config — `billing_enabled` and `current_tos_version`

**Files:**
- Modify: `config/runtime.exs`
- Modify: `config/test.exs`

- [ ] **Step 1: Add config in runtime.exs**

Edit `config/runtime.exs`. Find the existing Paddle block (around line 977-993, starts with `if config_env() != :test do` and contains `paddle_api_key`). Immediately after the closing `end` of that block, add:

```elixir
# Onboarding wizard toggle. Active when Paddle API key is set (SaaS mode);
# disabled in self-host (no PADDLE_API_KEY → no payment → no wizard).
config :engram, :billing_enabled, System.get_env("PADDLE_API_KEY") != nil

# Current Terms of Service version. Must match the version exported by
# frontend/src/legal/terms-of-service.tsx. Bumping this re-prompts every
# user on next request via the RequireOnboarding plug.
config :engram, :current_tos_version, System.get_env("CURRENT_TOS_VERSION", "2026-05-15")
```

- [ ] **Step 2: Set test defaults in config/test.exs**

Edit `config/test.exs`. At the bottom of the file (before any final `end`), add:

```elixir
# Onboarding wizard defaults for tests. Individual tests can override
# via Application.put_env/3 in their setup blocks.
config :engram, :billing_enabled, true
config :engram, :current_tos_version, "2026-05-15"
```

- [ ] **Step 3: Run the full backend suite to confirm config loads cleanly**

```bash
mix test
```

Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add config/runtime.exs config/test.exs
git commit -m "feat(onboarding): add billing_enabled and current_tos_version config"
```

---

## Task 10: Frontend — `useOnboardingStatus` + `useAcceptTerms` hooks

**Files:**
- Modify: `frontend/src/api/queries.ts`

- [ ] **Step 1: Add the types and hooks**

Edit `frontend/src/api/queries.ts`. After the `BillingStatus` block (search for `// API key types` and insert above it), add:

```typescript
// Onboarding types

export interface OnboardingStatus {
  enabled: boolean
  terms_ok?: boolean
  subscription_ok?: boolean
  current_tos_version?: string
  next_step: 'agreement' | 'billing' | 'done'
}

// Onboarding hooks

export function useOnboardingStatus() {
  return useQuery({
    queryKey: ['onboarding', 'status'],
    queryFn: () => api.get<OnboardingStatus>('/onboarding/status'),
    staleTime: Infinity,
  })
}

export function useAcceptTerms() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (version: string) =>
      api.post<{ version: string; accepted_at: string }>('/onboarding/accept-terms', { version }),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ['onboarding', 'status'] })
    },
  })
}
```

- [ ] **Step 2: Type-check**

```bash
cd frontend && bun run tsc --noEmit
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/api/queries.ts
git commit -m "feat(onboarding): add useOnboardingStatus and useAcceptTerms hooks"
```

---

## Task 11: Frontend — TOS content module

The TOS lives as a `.tsx` file exporting `{version, Content}`. Avoids a markdown parser dep and keeps the version next to the body.

**Files:**
- Create: `frontend/src/legal/terms-of-service.tsx`

- [ ] **Step 1: Create the TOS module**

Create `frontend/src/legal/terms-of-service.tsx`:

```tsx
export const TERMS_VERSION = '2026-05-15'

export function TermsContent() {
  return (
    <>
      <h2>Terms of Service</h2>
      <p>
        <strong>Last updated:</strong> {TERMS_VERSION}
      </p>
      <p>
        Engram (&quot;we&quot;, &quot;our&quot;) operates a knowledge-base service that stores and
        indexes notes you choose to sync to your account. By creating an account you agree to these
        Terms.
      </p>
      <h3>1. Account</h3>
      <p>
        You are responsible for the security of your credentials and for any activity on your
        account.
      </p>
      <h3>2. Content</h3>
      <p>
        You retain ownership of your notes. We process them only to provide the service
        (storage, indexing, search) and never sell or share them.
      </p>
      <h3>3. Subscriptions and billing</h3>
      <p>
        Paid plans renew automatically until cancelled. Billing is handled by Paddle as our
        Merchant of Record; their terms apply to the payment itself.
      </p>
      <h3>4. Termination</h3>
      <p>
        You may cancel at any time from your account settings. We may suspend accounts that
        violate these Terms or applicable law.
      </p>
      <h3>5. Changes</h3>
      <p>
        We may update these Terms; the version date at the top reflects the current revision.
        Continued use after a revision constitutes acceptance.
      </p>
      <p>
        <em>
          Placeholder content. Replace with reviewed legal text before launch — coordination item
          tracked in the spec at docs/superpowers/specs/2026-05-15-signup-wizard-design.md.
        </em>
      </p>
    </>
  )
}
```

- [ ] **Step 2: Commit**

```bash
git add frontend/src/legal/terms-of-service.tsx
git commit -m "feat(onboarding): add TOS content module (placeholder body)"
```

---

## Task 12: Frontend — `OnboardingGate` component

**Files:**
- Create: `frontend/src/onboarding/onboarding-gate.tsx`
- Create: `frontend/src/onboarding/onboarding-gate.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `frontend/src/onboarding/onboarding-gate.test.tsx`:

```tsx
import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import OnboardingGate from './onboarding-gate'

vi.mock('../api/queries', () => ({
  useOnboardingStatus: vi.fn(),
}))

import { useOnboardingStatus } from '../api/queries'

function renderWith(status: ReturnType<typeof useOnboardingStatus>) {
  vi.mocked(useOnboardingStatus).mockReturnValue(status as never)
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={['/']}>
        <Routes>
          <Route element={<OnboardingGate />}>
            <Route path="/" element={<div>dashboard</div>} />
          </Route>
          <Route path="/onboard/agreement" element={<div>agreement-step</div>} />
          <Route path="/onboard/billing" element={<div>billing-step</div>} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('OnboardingGate', () => {
  it('renders loading state while status query is pending', () => {
    renderWith({ data: undefined, isLoading: true, isError: false } as never)
    expect(screen.getByText(/loading/i)).toBeInTheDocument()
  })

  it('renders children when next_step is done', () => {
    renderWith({
      data: { enabled: true, next_step: 'done', terms_ok: true, subscription_ok: true },
      isLoading: false,
      isError: false,
    } as never)
    expect(screen.getByText('dashboard')).toBeInTheDocument()
  })

  it('renders children when wizard is disabled (self-host)', () => {
    renderWith({
      data: { enabled: false, next_step: 'done' },
      isLoading: false,
      isError: false,
    } as never)
    expect(screen.getByText('dashboard')).toBeInTheDocument()
  })

  it('redirects to /onboard/agreement when next_step=agreement', () => {
    renderWith({
      data: {
        enabled: true,
        next_step: 'agreement',
        terms_ok: false,
        subscription_ok: false,
      },
      isLoading: false,
      isError: false,
    } as never)
    expect(screen.getByText('agreement-step')).toBeInTheDocument()
  })

  it('redirects to /onboard/billing when next_step=billing', () => {
    renderWith({
      data: {
        enabled: true,
        next_step: 'billing',
        terms_ok: true,
        subscription_ok: false,
      },
      isLoading: false,
      isError: false,
    } as never)
    expect(screen.getByText('billing-step')).toBeInTheDocument()
  })
})
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd frontend && bun run vitest run src/onboarding/onboarding-gate.test.tsx
```

Expected: FAIL — module not found.

- [ ] **Step 3: Implement the component**

Create `frontend/src/onboarding/onboarding-gate.tsx`:

```tsx
import { Navigate, Outlet } from 'react-router'
import { useOnboardingStatus } from '../api/queries'

export default function OnboardingGate() {
  const { data, isLoading } = useOnboardingStatus()

  if (isLoading || !data) {
    return <p>Loading...</p>
  }

  if (!data.enabled || data.next_step === 'done') {
    return <Outlet />
  }

  return <Navigate to={`/onboard/${data.next_step}`} replace />
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd frontend && bun run vitest run src/onboarding/onboarding-gate.test.tsx
```

Expected: PASS — all 5 tests green.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/onboarding/onboarding-gate.tsx frontend/src/onboarding/onboarding-gate.test.tsx
git commit -m "feat(onboarding): add OnboardingGate component"
```

---

## Task 13: Frontend — `OnboardLayout` + `OnboardRedirect`

**Files:**
- Create: `frontend/src/onboarding/onboard-layout.tsx`
- Create: `frontend/src/onboarding/onboard-redirect.tsx`

- [ ] **Step 1: Implement `OnboardLayout`**

Create `frontend/src/onboarding/onboard-layout.tsx`:

```tsx
import { Outlet, useLocation } from 'react-router'
import { useAuthAdapter } from '../auth/use-auth-adapter'

export default function OnboardLayout() {
  const { signOut } = useAuthAdapter()
  const { pathname } = useLocation()

  const stepNumber = pathname.endsWith('/billing') ? 2 : 1

  return (
    <main className="onboard-layout">
      <header>
        <h1>Welcome to Engram</h1>
        <p>Step {stepNumber} of 2</p>
        <button type="button" onClick={() => signOut?.()}>
          Sign out
        </button>
      </header>
      <section>
        <Outlet />
      </section>
    </main>
  )
}
```

If `useAuthAdapter` does not expose `signOut`, render the button conditionally or remove it. Verify the hook signature at `frontend/src/auth/use-auth-adapter.ts` before saving.

- [ ] **Step 2: Implement `OnboardRedirect`**

Create `frontend/src/onboarding/onboard-redirect.tsx`:

```tsx
import { Navigate } from 'react-router'
import { useOnboardingStatus } from '../api/queries'

export default function OnboardRedirect() {
  const { data, isLoading } = useOnboardingStatus()
  if (isLoading || !data) return <p>Loading...</p>
  return <Navigate to={`/onboard/${data.next_step === 'done' ? '' : data.next_step}`} replace />
}
```

- [ ] **Step 3: Commit**

```bash
git add frontend/src/onboarding/onboard-layout.tsx frontend/src/onboarding/onboard-redirect.tsx
git commit -m "feat(onboarding): add OnboardLayout and OnboardRedirect"
```

---

## Task 14: Frontend — `AgreementPage`

**Files:**
- Create: `frontend/src/onboarding/agreement-page.tsx`
- Create: `frontend/src/onboarding/agreement-page.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `frontend/src/onboarding/agreement-page.test.tsx`:

```tsx
import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import AgreementPage from './agreement-page'

const mutate = vi.fn().mockResolvedValue({ version: '2026-05-15', accepted_at: 'now' })

vi.mock('../api/queries', () => ({
  useAcceptTerms: () => ({ mutateAsync: mutate, isPending: false }),
  useOnboardingStatus: () => ({
    data: { enabled: true, next_step: 'agreement', current_tos_version: '2026-05-15' },
    isLoading: false,
  }),
}))

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <AgreementPage />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('AgreementPage', () => {
  it('disables Continue until the agreement checkbox is checked', () => {
    renderPage()
    const button = screen.getByRole('button', { name: /continue/i })
    expect(button).toBeDisabled()

    fireEvent.click(screen.getByRole('checkbox', { name: /agree/i }))
    expect(button).not.toBeDisabled()
  })

  it('calls accept-terms with the current version on submit', async () => {
    renderPage()
    fireEvent.click(screen.getByRole('checkbox', { name: /agree/i }))
    fireEvent.click(screen.getByRole('button', { name: /continue/i }))

    await waitFor(() => expect(mutate).toHaveBeenCalledWith('2026-05-15'))
  })
})
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd frontend && bun run vitest run src/onboarding/agreement-page.test.tsx
```

Expected: FAIL — `agreement-page` module not found.

- [ ] **Step 3: Implement the page**

Create `frontend/src/onboarding/agreement-page.tsx`:

```tsx
import { useState } from 'react'
import { useAcceptTerms, useOnboardingStatus } from '../api/queries'
import { TERMS_VERSION, TermsContent } from '../legal/terms-of-service'

export default function AgreementPage() {
  const [agreed, setAgreed] = useState(false)
  const { data } = useOnboardingStatus()
  const { mutateAsync, isPending } = useAcceptTerms()

  const version = data?.current_tos_version ?? TERMS_VERSION

  async function submit() {
    await mutateAsync(version)
  }

  return (
    <section className="agreement-page">
      <article className="prose">
        <TermsContent />
      </article>
      <label>
        <input
          type="checkbox"
          checked={agreed}
          onChange={(e) => setAgreed(e.target.checked)}
        />
        I agree to the Terms of Service
      </label>
      <button type="button" onClick={submit} disabled={!agreed || isPending}>
        Continue
      </button>
    </section>
  )
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd frontend && bun run vitest run src/onboarding/agreement-page.test.tsx
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/onboarding/agreement-page.tsx frontend/src/onboarding/agreement-page.test.tsx
git commit -m "feat(onboarding): add AgreementPage with TOS acceptance"
```

---

## Task 15: Frontend — `OnboardBillingPage` wrapper

**Files:**
- Create: `frontend/src/onboarding/onboard-billing-page.tsx`

- [ ] **Step 1: Implement the wrapper**

Create `frontend/src/onboarding/onboard-billing-page.tsx`:

```tsx
import { useEffect } from 'react'
import { useNavigate } from 'react-router'
import { useOnboardingStatus } from '../api/queries'
import BillingPage from '../billing/billing-page'

export default function OnboardBillingPage() {
  const navigate = useNavigate()
  const { data } = useOnboardingStatus()

  useEffect(() => {
    if (data?.next_step === 'done') {
      navigate('/', { replace: true })
    }
  }, [data?.next_step, navigate])

  return (
    <section className="onboard-billing">
      <p>Pick a plan to start your 7-day free trial.</p>
      <BillingPage />
    </section>
  )
}
```

`BillingPage` already opens the Paddle overlay on plan selection and shows the trial state once `useBillingStatus()` reports an active subscription. The wrapper just adds the "pick a plan" lead and redirects to the dashboard the moment `next_step` flips to `done`.

- [ ] **Step 2: Verify the import is clean**

```bash
cd frontend && bun run tsc --noEmit
```

Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/onboarding/onboard-billing-page.tsx
git commit -m "feat(onboarding): add OnboardBillingPage wrapper"
```

---

## Task 16: Frontend router — wire `/onboard` + wrap dashboard in `OnboardingGate`

**Files:**
- Modify: `frontend/src/router.tsx`

- [ ] **Step 1: Add imports**

Edit `frontend/src/router.tsx`. After the existing component imports, add:

```typescript
import OnboardingGate from './onboarding/onboarding-gate'
import OnboardLayout from './onboarding/onboard-layout'
import OnboardRedirect from './onboarding/onboard-redirect'
import AgreementPage from './onboarding/agreement-page'
import OnboardBillingPage from './onboarding/onboard-billing-page'
```

- [ ] **Step 2: Restructure the authenticated routes**

Replace the existing `{ element: <AuthGuard />, children: [...] }` entry with:

```typescript
    // Authenticated routes
    {
      element: <AuthGuard />,
      children: [
        // Onboarding wizard — itself protected by AuthGuard, but NOT by
        // OnboardingGate (would redirect-loop).
        {
          path: '/onboard',
          element: <OnboardLayout />,
          children: [
            { index: true, element: <OnboardRedirect /> },
            { path: 'agreement', element: <AgreementPage /> },
            { path: 'billing', element: <OnboardBillingPage /> },
          ],
        },

        // Dashboard tree — gated by OnboardingGate.
        {
          element: <OnboardingGate />,
          children: [
            {
              element: <AppLayout />,
              children: [
                { path: ROUTES.HOME, element: <Dashboard /> },
                { path: '/note/*', element: <NotePage /> },
                { path: '/search', element: <SearchPage /> },
                { path: '/billing', element: <BillingPage /> },
                {
                  path: '/settings',
                  element: <SettingsLayout />,
                  children: [
                    { index: true, element: <Navigate to="appearance" replace /> },
                    { path: 'appearance', element: <AppearancePage /> },
                    { path: 'api-keys', element: <ApiKeysPage /> },
                    { path: 'encryption', element: <EncryptionPage /> },
                    { path: 'billing', element: <BillingPlaceholder /> },
                  ],
                },
              ],
            },
            { path: ROUTES.DEVICE_LINK, element: <DeviceLinkPage /> },
            { path: ROUTES.OAUTH_CONSENT, element: <OAuthAuthorizePage /> },
          ],
        },
      ],
    },
```

- [ ] **Step 3: Type-check**

```bash
cd frontend && bun run tsc --noEmit
```

Expected: no errors.

- [ ] **Step 4: Run the existing frontend test suite to confirm no regression**

```bash
cd frontend && bun run vitest run
```

Expected: all tests pass.

- [ ] **Step 5: Manual smoke test (optional but recommended)**

```bash
make dev          # in repo root, starts Phoenix + Vite
```

In a browser:
1. Sign up a new test user.
2. Verify redirect to `/onboard/agreement`.
3. Check the agreement box, click Continue → redirect to `/onboard/billing`.
4. Pick a plan, complete Paddle sandbox checkout.
5. Verify the dashboard appears (or expect spinner while webhook lands, then redirect).

- [ ] **Step 6: Commit**

```bash
git add frontend/src/router.tsx
git commit -m "feat(onboarding): wire /onboard routes and OnboardingGate into router"
```

---

## Task 17: E2E test — onboarding redirect + acceptance

This test exercises the backend gate end-to-end. Paddle checkout itself stays out of scope for automation (existing E2E pattern); the test stops after agreement acceptance and confirms the gate now reports `next_step=billing`.

**Files:**
- Create: `e2e/tests/test_onboarding.py`

- [ ] **Step 1: Write the test**

Create `e2e/tests/test_onboarding.py`:

```python
"""Onboarding wizard: new user must accept TOS before reaching the dashboard."""

import secrets
from datetime import datetime

import pytest

from helpers.api import ApiClient
from helpers.auth import get_auth_provider

API_URL = "http://localhost:4000"


@pytest.fixture(scope="module")
def onboarding_user():
    """Fresh user for onboarding tests — isolated from sync fixtures."""
    ts = datetime.now().strftime("%Y%m%d%H%M%S%f")
    email = f"e2e-onboard-{ts}@example.com"
    password = secrets.token_urlsafe(32)
    provider = get_auth_provider(API_URL)
    _, api_key = provider.provision_user(email, password)
    return email, api_key


def test_new_user_gets_onboarding_required_on_protected_route(onboarding_user):
    """A user with no TOS acceptance and no subscription is gated."""
    _, api_key = onboarding_user
    api = ApiClient(API_URL, api_key)

    resp = api.session.get(f"{API_URL}/api/folders/list")
    assert resp.status_code == 403
    body = resp.json()
    assert body["error"] == "onboarding_required"
    assert "terms" in body["missing"]
    assert "subscription" in body["missing"]


def test_status_endpoint_reports_agreement_step(onboarding_user):
    _, api_key = onboarding_user
    api = ApiClient(API_URL, api_key)

    resp = api.session.get(f"{API_URL}/api/onboarding/status")
    assert resp.status_code == 200
    body = resp.json()
    assert body["enabled"] is True
    assert body["next_step"] == "agreement"
    assert body["terms_ok"] is False


def test_accept_terms_advances_to_billing_step(onboarding_user):
    _, api_key = onboarding_user
    api = ApiClient(API_URL, api_key)

    status_before = api.session.get(f"{API_URL}/api/onboarding/status").json()
    current_version = status_before["current_tos_version"]

    accept = api.session.post(
        f"{API_URL}/api/onboarding/accept-terms",
        json={"version": current_version},
    )
    assert accept.status_code == 201

    status_after = api.session.get(f"{API_URL}/api/onboarding/status").json()
    assert status_after["terms_ok"] is True
    assert status_after["next_step"] == "billing"


def test_protected_route_still_403_with_missing_subscription(onboarding_user):
    """Terms accepted but no subscription → gate still blocks, missing=['subscription']."""
    _, api_key = onboarding_user
    api = ApiClient(API_URL, api_key)

    resp = api.session.get(f"{API_URL}/api/folders/list")
    assert resp.status_code == 403
    body = resp.json()
    assert body["missing"] == ["subscription"]
```

- [ ] **Step 2: Bring up the Docker stack**

```bash
make backend-up
```

(Or `docker compose -f docker-compose.elixir.yml up -d` if `make backend-up` is unavailable.) Wait until `/api/health` returns 200:

```bash
until curl -fs http://localhost:4000/api/health > /dev/null; do sleep 1; done
```

- [ ] **Step 3: Run the new E2E test**

```bash
python3 -m pytest e2e/tests/test_onboarding.py -v
```

Expected: all four tests pass.

- [ ] **Step 4: Tear down the stack**

```bash
make backend-down
```

- [ ] **Step 5: Commit**

```bash
git add e2e/tests/test_onboarding.py
git commit -m "test(onboarding): e2e for gate + TOS acceptance flow"
```

---

## Task 18: Final integration check + PR

- [ ] **Step 1: Run the full backend suite**

```bash
mix test
```

Expected: all pass.

- [ ] **Step 2: Run the lint stack**

```bash
mix format --check-formatted
mix compile --warnings-as-errors --force
mix credo --strict --mute-exit-status
mix sobelow --exit low
```

Expected: format clean, no warnings-as-errors, Credo/Sobelow at-or-below baseline.

- [ ] **Step 3: Run the frontend test suite + typecheck**

```bash
cd frontend && bun run vitest run && bun run tsc --noEmit
```

Expected: all pass.

- [ ] **Step 4: Bump the version**

Edit `mix.exs`, bump the `version:` string by one patch (e.g., `0.5.106` → `0.5.107`). Required by pre-push hook.

```bash
git add mix.exs
git commit -m "chore: bump version for signup wizard"
```

- [ ] **Step 5: Push the branch and open PR**

```bash
git push -u origin feat/signup-wizard
gh pr create --title "feat(onboarding): forced three-phase signup wizard" --body "$(cat <<'EOF'
## Summary

- New `RequireOnboarding` plug gates `/api/notes`, `/api/search`, etc. behind TOS acceptance + active subscription
- New `user_agreements` table (versioned, RLS-isolated) records TOS acceptances
- Frontend `OnboardingGate` redirects new users through `/onboard/agreement` → `/onboard/billing` → dashboard
- Self-host bypass: when `PADDLE_API_KEY` is unset, `:engram, :billing_enabled` is false and the wizard short-circuits entirely

Spec: `docs/superpowers/specs/2026-05-15-signup-wizard-design.md`

## Test plan

- [ ] `mix test` — all backend tests pass including new plug, context, controller, and integration tests
- [ ] `bun run vitest run` — frontend `OnboardingGate` and `AgreementPage` component tests pass
- [ ] `pytest e2e/tests/test_onboarding.py` — E2E confirms 403 on protected route, status endpoint, accept-terms advance
- [ ] Manual: sign up → see `/onboard/agreement` → accept → see `/onboard/billing` → complete Paddle sandbox checkout → land on dashboard
- [ ] Manual self-host: start Phoenix without `PADDLE_API_KEY` → sign up → no redirect; reach dashboard immediately
- [ ] Manual TOS bump: bump `CURRENT_TOS_VERSION` env, restart → existing user re-prompted on next request

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 6: Note the PR URL in chat for the user.**

---

## Self-review

**Spec coverage:** every spec section maps to at least one task:

| Spec section | Task(s) |
|---|---|
| Decisions table | Tasks 1, 6, 9 (data model + plug + config) |
| Data model | Tasks 1, 3 |
| Config | Task 9 |
| Backend plug | Task 6 |
| Backend endpoints | Tasks 7, 8 |
| Frontend gate | Task 12 |
| Frontend components | Tasks 13, 14, 15 |
| Queries hook | Task 10 |
| TOS content | Task 11 |
| Data flow scenarios | Covered by tests in Tasks 5, 6, 7, 8, 12, 14 |
| Error handling | Tests in Tasks 6, 7 cover 403 shape; webhook-delay/refetch is a UX detail of the existing BillingPage |
| Testing strategy | Each TDD task covers its layer; Task 17 covers E2E |
| Files touched preview | Matches Tasks 1–17 file map |
| Out of scope | Honored: no Privacy Policy, no decline flow, no admin override, no real-time broadcast |

**Placeholder scan:** no "TBD", "implement later", or "similar to Task N" placeholders. All code blocks are complete.

**Type consistency:**
- `Engram.Onboarding.accept_terms/3` signature matches across Tasks 4, 5, 7, 8.
- `Engram.Onboarding.status/1` return shape matches across Tasks 5, 6, 7.
- `OnboardingStatus` TypeScript interface matches the JSON shape in Task 8's controller.
- `useOnboardingStatus` / `useAcceptTerms` names are consistent in Tasks 10, 12, 14.
- `TERMS_VERSION` / `TermsContent` exports consistent in Tasks 11, 14.

**Known risk:** Task 3's `inet` type handling. The plan recommends declaring `field :ip_address, :string` and letting Postgres cast strings to `inet` on input — this avoids adding `ecto_network` as a dep but requires verification at run time. If insertion fails on the cast, switch the DB column to `:text` (no functional impact, just stores the IP as plain text).

---

Plan complete and saved to `docs/superpowers/plans/2026-05-15-signup-wizard.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
