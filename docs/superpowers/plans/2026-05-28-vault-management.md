# Vault Management Settings Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Vaults settings page where users list, rename, set-default, create, and soft-delete vaults (30-day grace), restore from trash, or purge immediately — plus a deletion-notice email.

**Architecture:** Reuse the existing `deleted_at` soft-delete + `CleanupVault` 30-day machinery. Add backend context functions (`list_deleted_vaults`, `restore_vault`, `purge_vault`), an idempotency age-guard on `CleanupVault`, three controller actions + routes, and an Oban-driven deletion email. Build the React settings section against the existing TanStack Query + shadcn/ui patterns.

**Tech Stack:** Elixir/Phoenix (Ecto, Oban, ExUnit), React + TypeScript (TanStack Query, vitest + Testing Library), Tailwind.

**Spec:** `docs/superpowers/specs/2026-05-28-vault-management-design.md`

**Repo:** `engram-app/engram`. Backend paths are repo-root-relative; frontend paths are under `frontend/`.

**Baseline before starting:** run `mix test` and (in `frontend/`) `bun run test` once to confirm a green tree.

---

## File Structure

**Backend (create):**
- `lib/engram/workers/vault_deleted_email.ex` — Oban worker that sends the deletion notice.

**Backend (modify):**
- `lib/engram/vaults.ex` — add `list_deleted_vaults/1`, `restore_vault/2`, `purge_vault/2`, `fetch_deleted/2`; enqueue email in `delete_vault/2`.
- `lib/engram/workers/cleanup_vault.ex` — age-guard + `enqueue_now/2` (force purge).
- `lib/engram/mailer.ex` — `send_vault_deletion_notice/4`.
- `lib/engram_web/controllers/vaults_controller.ex` — `index` deleted branch, `restore`, `purge`, `deleted_vault_json`.
- `lib/engram_web/router.ex` — `POST /vaults/:id/restore`, `POST /vaults/:id/purge`.

**Frontend (create):**
- `frontend/src/settings/vaults-page.tsx`
- `frontend/src/settings/vaults/active-vaults-section.tsx`
- `frontend/src/settings/vaults/deleted-vaults-section.tsx`
- `frontend/src/layout/empty-vault-state.tsx`
- matching `*.test.tsx` for each.

**Frontend (modify):**
- `frontend/src/api/client.ts` — add `api.patch`.
- `frontend/src/api/queries.ts` — `Vault` fields + 6 hooks.
- `frontend/src/settings/sections.ts` — register Vaults.
- `frontend/src/router.tsx` — `/settings/vaults` route.

---

## PHASE 1 — BACKEND

### Task 1: `Vaults.list_deleted_vaults/1` + `fetch_deleted/2`

**Files:**
- Modify: `lib/engram/vaults.ex`
- Test: `test/engram/vaults_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram/vaults_test.exs` inside the module:

```elixir
describe "list_deleted_vaults/1" do
  setup %{user: user} do
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
    :ok
  end

  test "returns only soft-deleted vaults, newest-deleted first", %{user: user} do
    {:ok, keep} = Vaults.create_vault(user, %{name: "Keep"})
    {:ok, gone} = Vaults.create_vault(user, %{name: "Gone"})
    {:ok, _} = Vaults.delete_vault(user, gone.id)

    deleted = Vaults.list_deleted_vaults(user)

    assert Enum.map(deleted, & &1.id) == [gone.id]
    assert keep.id not in Enum.map(deleted, & &1.id)
    assert hd(deleted).name == "Gone"
  end

  test "excludes other users' deleted vaults", %{user: user, other_user: other} do
    insert(:user_limit_override, user: other, key: "vaults_cap", value: %{"v" => 10})
    {:ok, mine} = Vaults.create_vault(user, %{name: "Mine"})
    {:ok, theirs} = Vaults.create_vault(other, %{name: "Theirs"})
    {:ok, _} = Vaults.delete_vault(user, mine.id)
    {:ok, _} = Vaults.delete_vault(other, theirs.id)

    assert Enum.map(Vaults.list_deleted_vaults(user), & &1.id) == [mine.id]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/vaults_test.exs -o "list_deleted_vaults/1"`
Expected: FAIL with `function Engram.Vaults.list_deleted_vaults/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

In `lib/engram/vaults.ex`, after `list_vaults/1` (around line 156) add:

```elixir
  @doc """
  Returns all soft-deleted vaults for a user, newest-deleted first.
  """
  def list_deleted_vaults(user) do
    user = fresh_user(user)

    {:ok, vaults} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from v in Vault,
            where: v.user_id == ^user.id and not is_nil(v.deleted_at),
            order_by: [desc: v.deleted_at, desc: v.id]
        )
      end)

    Enum.map(vaults, &decrypt_vault_if_needed(&1, user))
  end
```

And in the private helpers section (near `fetch_active/2`, ~line 388) add:

```elixir
  defp fetch_deleted(user_id, vault_id) do
    Repo.one(
      from v in Vault,
        where: v.user_id == ^user_id and v.id == ^vault_id and not is_nil(v.deleted_at)
    )
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/vaults_test.exs -o "list_deleted_vaults/1"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/vaults.ex test/engram/vaults_test.exs
git commit -m "feat(vaults): list_deleted_vaults + fetch_deleted helper"
```

---

### Task 2: `Vaults.restore_vault/2`

**Files:**
- Modify: `lib/engram/vaults.ex`
- Test: `test/engram/vaults_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
describe "restore_vault/2" do
  test "clears deleted_at and returns the vault", %{user: user} do
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
    {:ok, v} = Vaults.create_vault(user, %{name: "Temp"})
    {:ok, _} = Vaults.delete_vault(user, v.id)

    assert {:ok, restored} = Vaults.restore_vault(user, v.id)
    assert restored.id == v.id
    assert restored.deleted_at == nil
    assert Enum.map(Vaults.list_vaults(user), & &1.id) |> Enum.member?(v.id)
    assert Vaults.list_deleted_vaults(user) == []
  end

  test "blocks restore when it would exceed the vault cap", %{user: user} do
    # Cap of 1: create one, delete it, create a replacement, then try to restore.
    {:ok, first} = Vaults.create_vault(user, %{name: "First"})
    {:ok, _} = Vaults.delete_vault(user, first.id)
    {:ok, _replacement} = Vaults.create_vault(user, %{name: "Replacement"})

    assert {:error, :limit_reached} = Vaults.restore_vault(user, first.id)
    assert restored_ids(user) == []
  end

  test "returns :not_found for an active vault", %{user: user} do
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
    {:ok, v} = Vaults.create_vault(user, %{name: "Active"})
    assert {:error, :not_found} = Vaults.restore_vault(user, v.id)
  end

  test "returns :not_found for another user's deleted vault", %{user: user, other_user: other} do
    insert(:user_limit_override, user: other, key: "vaults_cap", value: %{"v" => 10})
    {:ok, v} = Vaults.create_vault(other, %{name: "Theirs"})
    {:ok, _} = Vaults.delete_vault(other, v.id)
    assert {:error, :not_found} = Vaults.restore_vault(user, v.id)
  end

  defp restored_ids(user), do: Enum.map(Vaults.list_deleted_vaults(user), & &1.id)
end
```

(Place the `defp restored_ids/1` helper at module level if your test module rejects describe-local defs; ExUnit allows module-level `defp`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/vaults_test.exs -o "restore_vault/2"`
Expected: FAIL with `function Engram.Vaults.restore_vault/2 is undefined`.

- [ ] **Step 3: Write minimal implementation**

In `lib/engram/vaults.ex`, after `delete_vault/2` (around line 324) add:

```elixir
  @doc """
  Restores a soft-deleted vault by clearing deleted_at.

  Refuses (`{:error, :limit_reached}`) if restoring would exceed the user's
  vault cap. The vault is restored as non-default; the user re-sets default
  explicitly. The pending CleanupVault job becomes a no-op once deleted_at is nil.

  Returns {:ok, vault}, {:error, :limit_reached}, or {:error, :not_found}.
  """
  def restore_vault(user, vault_id) do
    user = fresh_user(user)

    Repo.with_tenant(user.id, fn ->
      case fetch_deleted(user.id, vault_id) do
        nil ->
          {:error, :not_found}

        vault ->
          active_count = count_vaults(user.id)

          case Billing.check_limit(user, :vaults_cap, active_count) do
            {:error, :limit_reached} ->
              {:error, :limit_reached}

            :ok ->
              vault
              |> Vault.changeset(%{deleted_at: nil})
              |> Repo.update()
              |> case do
                {:ok, v} ->
                  emit_vault_count(user.id, :restored)
                  {:ok, decrypt_vault_if_needed(v, user)}

                other ->
                  other
              end
          end
      end
    end)
    |> unwrap_transaction()
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/vaults_test.exs -o "restore_vault/2"`
Expected: PASS. (If `Vault.changeset` rejects `deleted_at: nil`, add `:deleted_at` to its `cast` list — it is already cast by `delete_vault`, so this should pass.)

- [ ] **Step 5: Commit**

```bash
git add lib/engram/vaults.ex test/engram/vaults_test.exs
git commit -m "feat(vaults): restore_vault with cap guard"
```

---

### Task 3: `CleanupVault` age-guard + `enqueue_now/2`

**Files:**
- Modify: `lib/engram/workers/cleanup_vault.ex`
- Test: `test/engram/workers/cleanup_vault_test.exs`

- [ ] **Step 1: Write the failing test**

Add (or create) `test/engram/workers/cleanup_vault_test.exs`:

```elixir
defmodule Engram.Workers.CleanupVaultTest do
  use Engram.DataCase, async: true

  alias Engram.Repo
  alias Engram.Vaults
  alias Engram.Vaults.Vault
  alias Engram.Workers.CleanupVault

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
    %{user: user}
  end

  defp backdate_deleted_at(vault_id, days) do
    ts = DateTime.add(DateTime.utc_now(), -days * 86_400, :second) |> DateTime.truncate(:second)
    from(v in Vault, where: v.id == ^vault_id)
    |> Repo.update_all(set: [deleted_at: ts])
  end

  test "skips when the vault was restored (deleted_at nil)", %{user: user} do
    {:ok, v} = Vaults.create_vault(user, %{name: "V"})
    assert :ok = CleanupVault.perform_cleanup(v.id, user.id)
    assert Repo.get(Vault, v.id, skip_tenant_check: true)
  end

  test "snoozes when deleted_at is younger than 30 days", %{user: user} do
    {:ok, v} = Vaults.create_vault(user, %{name: "V"})
    {:ok, _} = Vaults.delete_vault(user, v.id)
    backdate_deleted_at(v.id, 5)

    assert {:snooze, secs} = CleanupVault.perform_cleanup(v.id, user.id)
    assert secs > 0
    assert Repo.get(Vault, v.id, skip_tenant_check: true)
  end

  test "purges when deleted_at is older than 30 days", %{user: user} do
    {:ok, v} = Vaults.create_vault(user, %{name: "V"})
    {:ok, _} = Vaults.delete_vault(user, v.id)
    backdate_deleted_at(v.id, 31)

    assert :ok = CleanupVault.perform_cleanup(v.id, user.id)
    refute Repo.get(Vault, v.id, skip_tenant_check: true)
  end

  test "force purges immediately regardless of age", %{user: user} do
    {:ok, v} = Vaults.create_vault(user, %{name: "V"})
    {:ok, _} = Vaults.delete_vault(user, v.id)
    # freshly deleted (age ~0) but force=true

    assert :ok = CleanupVault.perform_cleanup(v.id, user.id, force: true)
    refute Repo.get(Vault, v.id, skip_tenant_check: true)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/workers/cleanup_vault_test.exs`
Expected: FAIL — the snooze test fails (current code purges young vaults) and `perform_cleanup/3` is undefined.

- [ ] **Step 3: Write minimal implementation**

In `lib/engram/workers/cleanup_vault.ex`:

Add an `enqueue_now/2` after `enqueue/2`:

```elixir
  @doc """
  Enqueues an immediate (unscheduled) force-purge. Used by the "delete
  permanently now" path — bypasses the retention age guard.
  """
  def enqueue_now(vault_id, user_id) do
    %{vault_id: vault_id, user_id: user_id, force: true}
    |> new()
    |> Oban.insert()
  end
```

Replace `perform/1` and `perform_cleanup/2` with:

```elixir
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"vault_id" => vault_id, "user_id" => user_id} = args}) do
    perform_cleanup(vault_id, user_id, force: Map.get(args, "force", false))
  end

  @doc false
  def perform_cleanup(vault_id, user_id, opts \\ []) do
    force = Keyword.get(opts, :force, false)
    vault = Repo.get(Vault, vault_id, skip_tenant_check: true)
    _ = user_id

    cond do
      is_nil(vault) ->
        Logger.info("CleanupVault: vault #{vault_id} not found — skipping")
        :ok

      is_nil(vault.deleted_at) ->
        Logger.info("CleanupVault: vault #{vault_id} was restored — skipping")
        :ok

      not force and (age = retention_age_secs(vault)) < @retention_secs ->
        snooze = @retention_secs - age
        Logger.info("CleanupVault: vault #{vault_id} not yet at retention — snoozing #{snooze}s")
        {:snooze, snooze}

      true ->
        Logger.info("CleanupVault: starting hard-delete for vault #{vault_id}")
        run_cleanup(vault)
    end
  end

  @retention_secs @retention_days * 86_400

  defp retention_age_secs(vault) do
    DateTime.diff(DateTime.utc_now(), vault.deleted_at, :second)
  end
```

(Keep the existing `@retention_days 30` attribute; the `@retention_secs` module attribute must appear after it — place it just above the `perform/1` clause or with the other attributes.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/workers/cleanup_vault_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/engram/workers/cleanup_vault.ex test/engram/workers/cleanup_vault_test.exs
git commit -m "fix(cleanup_vault): retention age guard + force purge path"
```

---

### Task 4: `Vaults.purge_vault/2`

**Files:**
- Modify: `lib/engram/vaults.ex`
- Test: `test/engram/vaults_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
describe "purge_vault/2" do
  use Oban.Testing, repo: Engram.Repo

  test "enqueues an immediate force cleanup for a soft-deleted vault", %{user: user} do
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
    {:ok, v} = Vaults.create_vault(user, %{name: "Doomed"})
    {:ok, _} = Vaults.delete_vault(user, v.id)

    assert {:ok, vault} = Vaults.purge_vault(user, v.id)
    assert vault.id == v.id

    assert_enqueued(
      worker: Engram.Workers.CleanupVault,
      args: %{vault_id: v.id, user_id: user.id, force: true}
    )
  end

  test "returns :not_found for an active vault", %{user: user} do
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
    {:ok, v} = Vaults.create_vault(user, %{name: "Active"})
    assert {:error, :not_found} = Vaults.purge_vault(user, v.id)
  end
end
```

(If `use Oban.Testing` inside a `describe` is rejected, move it to the top of the module under `use Engram.DataCase`.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram/vaults_test.exs -o "purge_vault/2"`
Expected: FAIL with `function Engram.Vaults.purge_vault/2 is undefined`.

- [ ] **Step 3: Write minimal implementation**

In `lib/engram/vaults.ex`, after `restore_vault/2` add:

```elixir
  @doc """
  Immediately hard-deletes a soft-deleted vault by enqueuing a force CleanupVault
  job. Only soft-deleted vaults can be purged.

  Returns {:ok, vault} or {:error, :not_found}.
  """
  def purge_vault(user, vault_id) do
    user = fresh_user(user)

    Repo.with_tenant(user.id, fn ->
      case fetch_deleted(user.id, vault_id) do
        nil ->
          {:error, :not_found}

        vault ->
          {:ok, _job} = Engram.Workers.CleanupVault.enqueue_now(vault.id, vault.user_id)
          {:ok, vault}
      end
    end)
    |> unwrap_transaction()
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram/vaults_test.exs -o "purge_vault/2"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram/vaults.ex test/engram/vaults_test.exs
git commit -m "feat(vaults): purge_vault force-cleanup path"
```

---

### Task 5: Controller actions + routes + `purge_at`

**Files:**
- Modify: `lib/engram_web/controllers/vaults_controller.ex`
- Modify: `lib/engram_web/router.ex`
- Test: `test/engram_web/controllers/vaults_controller_test.exs`

- [ ] **Step 1: Write the failing test**

Add to `test/engram_web/controllers/vaults_controller_test.exs`:

```elixir
describe "GET /api/vaults?deleted=true" do
  test "lists soft-deleted vaults with a purge_at", %{conn: conn, user: user} do
    {:ok, v} = Vaults.create_vault(user, %{name: "Trashed"})
    {:ok, _} = Vaults.delete_vault(user, v.id)

    body = conn |> get("/api/vaults?deleted=true") |> json_response(200)
    [item] = body["vaults"]
    assert item["id"] == v.id
    assert item["deleted_at"]
    assert item["purge_at"]
  end

  test "active listing excludes deleted vaults", %{conn: conn, user: user} do
    {:ok, v} = Vaults.create_vault(user, %{name: "Trashed"})
    {:ok, _} = Vaults.delete_vault(user, v.id)

    body = conn |> get("/api/vaults") |> json_response(200)
    assert body["vaults"] == []
  end
end

describe "POST /api/vaults/:id/restore" do
  test "restores a deleted vault", %{conn: conn, user: user} do
    {:ok, v} = Vaults.create_vault(user, %{name: "Back"})
    {:ok, _} = Vaults.delete_vault(user, v.id)

    body = conn |> post("/api/vaults/#{v.id}/restore") |> json_response(200)
    assert body["vault"]["id"] == v.id
  end

  test "returns 402 when over cap", %{conn: conn} do
    # fresh user with default cap (1), no override
    other = insert(:user)
    {:ok, raw_key, _} = Engram.Accounts.create_api_key(other, "k")
    grant_api_write!(other)
    oconn = build_conn() |> put_req_header("authorization", "Bearer #{raw_key}")

    {:ok, first} = Vaults.create_vault(other, %{name: "First"})
    {:ok, _} = Vaults.delete_vault(other, first.id)
    {:ok, _} = Vaults.create_vault(other, %{name: "Replacement"})

    body = oconn |> post("/api/vaults/#{first.id}/restore") |> json_response(402)
    assert body["error"] == "vault_limit_reached"
  end

  test "returns 404 for an active vault", %{conn: conn, user: user} do
    {:ok, v} = Vaults.create_vault(user, %{name: "Active"})
    conn |> post("/api/vaults/#{v.id}/restore") |> json_response(404)
  end
end

describe "POST /api/vaults/:id/purge" do
  test "purges a deleted vault", %{conn: conn, user: user} do
    {:ok, v} = Vaults.create_vault(user, %{name: "Doomed"})
    {:ok, _} = Vaults.delete_vault(user, v.id)

    body = conn |> post("/api/vaults/#{v.id}/purge") |> json_response(200)
    assert body["purged"] == true
    assert body["id"] == v.id
  end

  test "returns 404 for an active vault", %{conn: conn, user: user} do
    {:ok, v} = Vaults.create_vault(user, %{name: "Active"})
    conn |> post("/api/vaults/#{v.id}/purge") |> json_response(404)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/engram_web/controllers/vaults_controller_test.exs`
Expected: FAIL — routes not found (Phoenix raises `no route found` → 404/500) and `?deleted=true` returns the active listing.

- [ ] **Step 3: Write minimal implementation**

In `lib/engram_web/router.ex`, find the vaults routes block (the `get/post/patch/delete "/vaults"...` lines, ~155-161) and add two routes immediately after the existing `delete "/vaults/:id"`:

```elixir
    post "/vaults/:id/restore", VaultsController, :restore
    post "/vaults/:id/purge", VaultsController, :purge
```

In `lib/engram_web/controllers/vaults_controller.ex`, replace `index/2` and add the two actions + JSON helper. New `index`:

```elixir
  def index(conn, %{"deleted" => "true"}) do
    user = conn.assigns.current_user
    vaults = Vaults.list_deleted_vaults(user)
    json(conn, %{vaults: Enum.map(vaults, &deleted_vault_json(&1, user))})
  end

  def index(conn, _params) do
    user = conn.assigns.current_user
    vaults = Vaults.list_vaults(user)
    json(conn, %{vaults: Enum.map(vaults, &vault_json(&1, user))})
  end
```

Add after `delete/2` (before the `register` section or near it):

```elixir
  # ── restore ──────────────────────────────────────────────────────────────────

  def restore(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case parse_id(id) do
      {:ok, vault_id} ->
        case Vaults.restore_vault(user, vault_id) do
          {:ok, vault} ->
            json(conn, %{vault: vault_json(vault, user)})

          {:error, :limit_reached} ->
            limit = Billing.effective_limit(user, :vaults_cap)

            conn
            |> put_status(402)
            |> json(%{error: "vault_limit_reached", limit: limit})

          {:error, :not_found} ->
            not_found(conn)
        end

      :error ->
        not_found(conn)
    end
  end

  # ── purge (immediate hard delete) ──────────────────────────────────────────────

  def purge(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case parse_id(id) do
      {:ok, vault_id} ->
        case Vaults.purge_vault(user, vault_id) do
          {:ok, _vault} -> json(conn, %{purged: true, id: vault_id})
          {:error, :not_found} -> not_found(conn)
        end

      :error ->
        not_found(conn)
    end
  end
```

Add the deleted-vault JSON helper in the private section, next to `vault_json/2`:

```elixir
  defp deleted_vault_json(vault, user) do
    vault
    |> vault_json(user)
    |> Map.merge(%{
      deleted_at: vault.deleted_at,
      purge_at: purge_at(vault.deleted_at)
    })
  end

  defp purge_at(nil), do: nil
  defp purge_at(deleted_at), do: DateTime.add(deleted_at, 30 * 86_400, :second)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/engram_web/controllers/vaults_controller_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/engram_web/controllers/vaults_controller.ex lib/engram_web/router.ex test/engram_web/controllers/vaults_controller_test.exs
git commit -m "feat(vaults): restore/purge endpoints + deleted listing"
```

---

### Task 6: Deletion-notice email (Mailer + worker + enqueue)

**Files:**
- Modify: `lib/engram/mailer.ex`
- Create: `lib/engram/workers/vault_deleted_email.ex`
- Modify: `lib/engram/vaults.ex` (`delete_vault/2`)
- Test: `test/engram/mailer_test.exs`, `test/engram/workers/vault_deleted_email_test.exs`

- [ ] **Step 1: Write the failing test (mailer)**

Add to `test/engram/mailer_test.exs` (create if absent, mirroring existing mailer tests; the test provider is configured in `config/test.exs`):

```elixir
defmodule Engram.MailerVaultNoticeTest do
  use Engram.DataCase, async: true
  alias Engram.Mailer

  test "send_vault_deletion_notice returns :ok and includes the manage link" do
    user = insert(:user, email: "u@example.com")
    assert :ok =
             Mailer.send_vault_deletion_notice(
               user,
               "My Vault",
               "June 27, 2026",
               "https://app.engram.page/settings/vaults?highlight=1"
             )
  end
end
```

(If the test provider captures the sent body, additionally assert the body contains the URL. Match the assertion style of the existing `mailer_test.exs`.)

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/engram/mailer_test.exs`
Expected: FAIL with `function Engram.Mailer.send_vault_deletion_notice/4 is undefined`.

- [ ] **Step 3: Implement the mailer function**

In `lib/engram/mailer.ex`, add after `send_account_deleted_notice/1`:

```elixir
  @doc """
  Notifies a user that a vault was soft-deleted and will be purged on
  `purge_date` (a preformatted string). `manage_url` deep-links to the vault
  settings page where they can restore or purge immediately.
  """
  def send_vault_deletion_notice(%User{email: email}, vault_name, purge_date, manage_url) do
    vault_name = Template.esc(vault_name)
    purge_date = Template.esc(purge_date)

    body = """
    <mj-text>Your Engram vault "#{vault_name}" has been deleted.</mj-text>
    <mj-text>It will be permanently removed on #{purge_date}. Until then you can
    restore it — or, if you meant to delete it, remove it permanently now — from
    your vault settings.</mj-text>
    <mj-button href="#{manage_url}" background-color="#5b5bd6">Manage vault</mj-button>
    <mj-text>No action is needed if you want it gone; it will be cleaned up
    automatically.</mj-text>
    """

    render_and_deliver(email, "Your Engram vault was deleted", body)
  end
```

- [ ] **Step 4: Run to verify the mailer test passes**

Run: `mix test test/engram/mailer_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the failing test (worker)**

Create `test/engram/workers/vault_deleted_email_test.exs`:

```elixir
defmodule Engram.Workers.VaultDeletedEmailTest do
  use Engram.DataCase, async: true

  alias Engram.Vaults
  alias Engram.Workers.VaultDeletedEmail

  setup do
    user = insert(:user, email: "u@example.com")
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
    %{user: user}
  end

  test "perform sends the notice for a soft-deleted vault", %{user: user} do
    {:ok, v} = Vaults.create_vault(user, %{name: "Gone"})
    {:ok, _} = Vaults.delete_vault(user, v.id)

    job = %Oban.Job{args: %{"user_id" => user.id, "vault_id" => v.id}}
    assert :ok = VaultDeletedEmail.perform(job)
  end

  test "perform is a no-op when the vault is missing", %{user: user} do
    job = %Oban.Job{args: %{"user_id" => user.id, "vault_id" => 999_999}}
    assert :ok = VaultDeletedEmail.perform(job)
  end
end
```

- [ ] **Step 6: Run to verify it fails**

Run: `mix test test/engram/workers/vault_deleted_email_test.exs`
Expected: FAIL — module does not exist.

- [ ] **Step 7: Implement the worker**

Create `lib/engram/workers/vault_deleted_email.ex`:

```elixir
defmodule Engram.Workers.VaultDeletedEmail do
  @moduledoc """
  Oban worker: emails a user that a vault was soft-deleted, with a link to the
  vault settings page (restore / purge-now). Self-host installs no-op via the
  NoOp mail provider. Sends asynchronously so the DELETE request is never
  blocked on mail delivery.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Mailer
  alias Engram.Repo
  alias Engram.Vaults.Vault

  require Logger

  @retention_days 30

  def enqueue(user_id, vault_id) do
    %{user_id: user_id, vault_id: vault_id}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id}}) do
    user = Repo.get(User, user_id, skip_tenant_check: true)
    vault = Repo.get(Vault, vault_id, skip_tenant_check: true)

    cond do
      is_nil(user) or is_nil(vault) ->
        :ok

      is_nil(vault.deleted_at) ->
        :ok

      true ->
        purge_at = DateTime.add(vault.deleted_at, @retention_days * 86_400, :second)
        purge_date = Calendar.strftime(purge_at, "%B %-d, %Y")
        manage_url = EngramWeb.Endpoint.url() <> "/settings/vaults?highlight=#{vault.id}"
        _ = Mailer.send_vault_deletion_notice(user, vault_name(vault, user), purge_date, manage_url)
        :ok
    end
  end

  defp vault_name(vault, user) do
    case Crypto.maybe_decrypt_vault_fields(vault, user) do
      {:ok, decrypted} -> decrypted.name
      _ -> vault.slug
    end
  end
end
```

- [ ] **Step 8: Run to verify the worker test passes**

Run: `mix test test/engram/workers/vault_deleted_email_test.exs`
Expected: PASS.

- [ ] **Step 9: Enqueue the email from `delete_vault/2`**

In `lib/engram/vaults.ex`, in the `{:ok, deleted}` branch of `delete_vault/2` (right after the existing `CleanupVault.enqueue` line, ~line 314):

```elixir
            {:ok, deleted} ->
              _ = Engram.Workers.CleanupVault.enqueue(deleted.id, deleted.user_id)
              _ = Engram.Workers.VaultDeletedEmail.enqueue(deleted.user_id, deleted.id)
              emit_vault_count(deleted.user_id, :deleted)
              result
```

- [ ] **Step 10: Verify delete enqueues the email**

Add to the `delete_vault/2` describe in `test/engram/vaults_test.exs`:

```elixir
  test "delete_vault enqueues the deletion-notice email", %{user: user} do
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
    {:ok, v} = Vaults.create_vault(user, %{name: "Bye"})
    {:ok, _} = Vaults.delete_vault(user, v.id)

    assert_enqueued(worker: Engram.Workers.VaultDeletedEmail, args: %{vault_id: v.id, user_id: user.id})
  end
```

(Ensure `use Oban.Testing, repo: Engram.Repo` is present at the top of the test module.)

Run: `mix test test/engram/vaults_test.exs`
Expected: PASS.

- [ ] **Step 11: Commit**

```bash
git add lib/engram/mailer.ex lib/engram/workers/vault_deleted_email.ex lib/engram/vaults.ex test/engram/mailer_test.exs test/engram/workers/vault_deleted_email_test.exs test/engram/vaults_test.exs
git commit -m "feat(vaults): deletion-notice email on soft-delete"
```

- [ ] **Step 12: Run the full backend suite**

Run: `mix test`
Expected: PASS. Fix any regressions before moving to the frontend.

---

## PHASE 2 — FRONTEND

All commands below run from `frontend/`.

### Task 7: `api.patch` + `Vault` fields + query hooks

**Files:**
- Modify: `frontend/src/api/client.ts`
- Modify: `frontend/src/api/queries.ts`

- [ ] **Step 1: Add `api.patch`**

In `frontend/src/api/client.ts`, add to the `api` object (after `post`):

```typescript
  async patch<T>(path: string, body?: unknown): Promise<T> {
    const res = await authFetch(path, {
      method: 'PATCH',
      body: body ? JSON.stringify(body) : undefined,
    })
    return res.json()
  },
```

- [ ] **Step 2: Extend the `Vault` type**

In `frontend/src/api/queries.ts`, add to the `Vault` interface:

```typescript
  deleted_at?: string | null
  purge_at?: string | null
```

- [ ] **Step 3: Add the hooks**

In `frontend/src/api/queries.ts`, after the existing vault hooks add:

```typescript
export function useDeletedVaults() {
  return useQuery({
    queryKey: ['vaults', 'deleted'],
    queryFn: () => api.get<{ vaults: Vault[] }>('/vaults?deleted=true'),
    select: (data) => data.vaults,
  })
}

export function useDeleteVault() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: number) => api.del<{ deleted: boolean }>(`/vaults/${id}`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['vaults'] }),
  })
}

export function useRestoreVault() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: number) => api.post<{ vault: Vault }>(`/vaults/${id}/restore`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['vaults'] }),
  })
}

export function usePurgeVault() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (id: number) => api.post<{ purged: boolean }>(`/vaults/${id}/purge`),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['vaults'] }),
  })
}

export function useUpdateVault() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: ({ id, ...attrs }: { id: number; name?: string; description?: string; is_default?: boolean }) =>
      api.patch<{ vault: Vault }>(`/vaults/${id}`, attrs),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['vaults'] }),
  })
}

export function useCreateVault() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: (attrs: { name: string; description?: string }) =>
      api.post<{ vault: Vault }>('/vaults', attrs),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['vaults'] }),
  })
}
```

> Note: `invalidateQueries({ queryKey: ['vaults'] })` matches `['vaults','deleted']` by prefix, so both active and trash lists refetch — no separate invalidation needed.

- [ ] **Step 4: Typecheck**

Run: `bun run build` (or `bunx tsc --noEmit` if defined)
Expected: no type errors.

- [ ] **Step 5: Commit**

```bash
git add src/api/client.ts src/api/queries.ts
git commit -m "feat(frontend): vault management api hooks"
```

---

### Task 8: Active vaults section (list, rename, set default, delete)

**Files:**
- Create: `frontend/src/settings/vaults/active-vaults-section.tsx`
- Test: `frontend/src/settings/vaults/active-vaults-section.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `frontend/src/settings/vaults/active-vaults-section.test.tsx`:

```tsx
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'

const deleteMutate = vi.fn()
const updateMutate = vi.fn()
const vaults = [
  { id: 1, name: 'Work', description: null, slug: 'work', is_default: true, created_at: '', encrypted: true },
  { id: 2, name: 'Personal', description: null, slug: 'personal', is_default: false, created_at: '', encrypted: true },
]

vi.mock('@/api/queries', () => ({
  useVaults: () => ({ data: vaults, isLoading: false }),
  useDeleteVault: () => ({ mutate: deleteMutate, isPending: false }),
  useUpdateVault: () => ({ mutate: updateMutate, isPending: false }),
}))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { ActiveVaultsSection } from './active-vaults-section'

describe('ActiveVaultsSection', () => {
  beforeEach(() => vi.clearAllMocks())

  it('lists vaults and marks the default', () => {
    render(<ActiveVaultsSection />)
    expect(screen.getByText('Work')).toBeInTheDocument()
    expect(screen.getByText('Personal')).toBeInTheDocument()
    expect(screen.getByText(/default/i)).toBeInTheDocument()
  })

  it('keeps delete disabled until the vault name is typed', async () => {
    render(<ActiveVaultsSection />)
    fireEvent.click(screen.getAllByRole('button', { name: /^delete$/i })[0])
    const confirmBtn = screen.getByRole('button', { name: /delete vault/i })
    expect(confirmBtn).toBeDisabled()
    fireEvent.change(screen.getByLabelText(/type .*work.* to confirm/i), { target: { value: 'Work' } })
    expect(confirmBtn).toBeEnabled()
    fireEvent.click(confirmBtn)
    await waitFor(() => expect(deleteMutate).toHaveBeenCalledWith(1, expect.anything()))
  })

  it('sets a non-default vault as default', () => {
    render(<ActiveVaultsSection />)
    fireEvent.click(screen.getByRole('button', { name: /set default/i }))
    expect(updateMutate).toHaveBeenCalledWith({ id: 2, is_default: true }, expect.anything())
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun run test active-vaults-section`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Implement the component**

Create `frontend/src/settings/vaults/active-vaults-section.tsx`:

```tsx
import { useState } from 'react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from '@/settings/account/section-card'
import { useVaults, useDeleteVault, useUpdateVault, type Vault } from '@/api/queries'

const inputClass =
  'mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export function ActiveVaultsSection() {
  const { data: vaults, isLoading } = useVaults()

  return (
    <SettingsSectionCard title="Vaults" description="Rename, set a default, or delete your vaults.">
      {isLoading && <p className="text-sm text-muted-foreground">Loading…</p>}
      <ul className="divide-y divide-border">
        {(vaults ?? []).map((v) => (
          <VaultRow key={v.id} vault={v} />
        ))}
      </ul>
    </SettingsSectionCard>
  )
}

function VaultRow({ vault }: { vault: Vault }) {
  const update = useUpdateVault()
  const del = useDeleteVault()
  const [renaming, setRenaming] = useState(false)
  const [name, setName] = useState(vault.name)
  const [confirming, setConfirming] = useState(false)
  const [phrase, setPhrase] = useState('')

  function saveName() {
    const next = name.trim()
    if (next && next !== vault.name) {
      update.mutate({ id: vault.id, name: next }, { onError: () => toast.error('Rename failed') })
    }
    setRenaming(false)
  }

  return (
    <li className="py-3">
      <div className="flex items-center justify-between gap-3">
        {renaming ? (
          <input
            autoFocus
            className={inputClass}
            value={name}
            aria-label={`Rename ${vault.name}`}
            onChange={(e) => setName(e.target.value)}
            onBlur={saveName}
            onKeyDown={(e) => e.key === 'Enter' && saveName()}
          />
        ) : (
          <button type="button" className="text-sm font-medium text-foreground" onClick={() => setRenaming(true)}>
            {vault.name}
          </button>
        )}
        <div className="flex items-center gap-2">
          {vault.is_default ? (
            <span className="rounded bg-muted px-2 py-0.5 text-xs text-muted-foreground">Default</span>
          ) : (
            <Button
              variant="ghost"
              size="sm"
              onClick={() =>
                update.mutate({ id: vault.id, is_default: true }, { onError: () => toast.error('Could not set default') })
              }
            >
              Set default
            </Button>
          )}
          <Button variant="ghost" size="sm" onClick={() => setConfirming((c) => !c)}>
            Delete
          </Button>
        </div>
      </div>
      {confirming && (
        <form
          className="mt-3 rounded-md border border-destructive/40 bg-destructive/5 p-3"
          onSubmit={(e) => {
            e.preventDefault()
            del.mutate(vault.id, {
              onSuccess: () => toast.success('Vault deleted'),
              onError: () => toast.error('Delete failed'),
            })
          }}
        >
          <label className="block text-sm text-foreground">
            Type "{vault.name}" to confirm
            <input
              className={inputClass}
              aria-label={`Type ${vault.name} to confirm`}
              value={phrase}
              onChange={(e) => setPhrase(e.target.value)}
            />
          </label>
          <Button className="mt-3" type="submit" variant="destructive" size="sm" disabled={phrase !== vault.name}>
            Delete vault
          </Button>
        </form>
      )}
    </li>
  )
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bun run test active-vaults-section`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/settings/vaults/active-vaults-section.tsx src/settings/vaults/active-vaults-section.test.tsx
git commit -m "feat(frontend): active vaults section with rename/default/delete"
```

---

### Task 9: Recently deleted section (restore, purge, over-cap)

**Files:**
- Create: `frontend/src/settings/vaults/deleted-vaults-section.tsx`
- Test: `frontend/src/settings/vaults/deleted-vaults-section.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `frontend/src/settings/vaults/deleted-vaults-section.test.tsx`:

```tsx
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'

const restoreMutate = vi.fn()
const purgeMutate = vi.fn()
let deleted = [
  { id: 5, name: 'Old', description: null, slug: 'old', is_default: false, created_at: '', encrypted: true, deleted_at: '2026-05-28T00:00:00Z', purge_at: '2026-06-27T00:00:00Z' },
]
let activeCount = 1
const cap = 1

vi.mock('@/api/queries', () => ({
  useDeletedVaults: () => ({ data: deleted, isLoading: false }),
  useVaults: () => ({ data: new Array(activeCount).fill({ id: 99 }) }),
  useRestoreVault: () => ({ mutate: restoreMutate, isPending: false }),
  usePurgeVault: () => ({ mutate: purgeMutate, isPending: false }),
  useBillingConfig: () => ({ data: { vaults_cap: cap } }),
}))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { DeletedVaultsSection } from './deleted-vaults-section'

describe('DeletedVaultsSection', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    activeCount = 1
  })

  it('shows the purge date', () => {
    render(<DeletedVaultsSection />)
    expect(screen.getByText('Old')).toBeInTheDocument()
    expect(screen.getByText(/purges/i)).toBeInTheDocument()
  })

  it('disables restore when at the cap', () => {
    activeCount = 1 // cap is 1, so restoring would exceed
    render(<DeletedVaultsSection />)
    expect(screen.getByRole('button', { name: /restore/i })).toBeDisabled()
  })

  it('restores when under cap', async () => {
    activeCount = 0
    render(<DeletedVaultsSection />)
    const btn = screen.getByRole('button', { name: /restore/i })
    expect(btn).toBeEnabled()
    fireEvent.click(btn)
    await waitFor(() => expect(restoreMutate).toHaveBeenCalledWith(5, expect.anything()))
  })
})
```

> The cap source: this test mocks a `useBillingConfig` hook returning `{ vaults_cap }`. If the app already exposes the cap differently (e.g. on the config endpoint or a billing hook), use that real hook name in both the component and the mock. Confirm the actual hook in `src/api/queries.ts` / `src/config.ts` before implementing; the over-cap *logic* (disable when `activeCount >= cap`) is what matters.

- [ ] **Step 2: Run to verify it fails**

Run: `bun run test deleted-vaults-section`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Implement the component**

Create `frontend/src/settings/vaults/deleted-vaults-section.tsx`:

```tsx
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from '@/settings/account/section-card'
import {
  useDeletedVaults,
  useVaults,
  useRestoreVault,
  usePurgeVault,
  useBillingConfig,
  type Vault,
} from '@/api/queries'

export function DeletedVaultsSection() {
  const { data: deleted } = useDeletedVaults()
  if (!deleted || deleted.length === 0) return null

  return (
    <SettingsSectionCard
      title="Recently deleted"
      description="Deleted vaults are kept for 30 days. Restore them, or remove them permanently."
    >
      <ul className="divide-y divide-border">
        {deleted.map((v) => (
          <DeletedRow key={v.id} vault={v} />
        ))}
      </ul>
    </SettingsSectionCard>
  )
}

function DeletedRow({ vault }: { vault: Vault }) {
  const { data: active } = useVaults()
  const { data: billing } = useBillingConfig()
  const restore = useRestoreVault()
  const purge = usePurgeVault()

  const cap = billing?.vaults_cap ?? Infinity
  const activeCount = active?.length ?? 0
  const overCap = activeCount >= cap
  const purgeDate = vault.purge_at ? new Date(vault.purge_at).toLocaleDateString() : null

  return (
    <li className="flex items-center justify-between gap-3 py-3">
      <div>
        <p className="text-sm font-medium text-foreground">{vault.name}</p>
        {purgeDate && <p className="text-xs text-muted-foreground">Purges {purgeDate}</p>}
      </div>
      <div className="flex items-center gap-2">
        <Button
          variant="outline"
          size="sm"
          disabled={overCap || restore.isPending}
          title={overCap ? 'Restoring would exceed your vault limit. Upgrade or delete another vault first.' : undefined}
          onClick={() =>
            restore.mutate(vault.id, {
              onSuccess: () => toast.success('Vault restored'),
              onError: () => toast.error('Could not restore (vault limit reached?)'),
            })
          }
        >
          Restore
        </Button>
        <Button
          variant="destructive"
          size="sm"
          disabled={purge.isPending}
          onClick={() => {
            if (window.confirm(`Permanently delete "${vault.name}"? This cannot be undone.`)) {
              purge.mutate(vault.id, {
                onSuccess: () => toast.success('Vault permanently deleted'),
                onError: () => toast.error('Could not delete'),
              })
            }
          }}
        >
          Delete permanently
        </Button>
      </div>
    </li>
  )
}
```

> If a `useBillingConfig` hook does not exist, add a minimal one in `queries.ts` that reads `GET /billing/config` (which `CLAUDE.md` documents) and exposes `vaults_cap`, or derive the cap from the existing config object. Keep the disable logic identical.

- [ ] **Step 4: Run to verify it passes**

Run: `bun run test deleted-vaults-section`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add src/settings/vaults/deleted-vaults-section.tsx src/settings/vaults/deleted-vaults-section.test.tsx
git commit -m "feat(frontend): recently-deleted section with restore/purge"
```

---

### Task 10: Vaults page (create + compose sections + highlight)

**Files:**
- Create: `frontend/src/settings/vaults-page.tsx`
- Test: `frontend/src/settings/vaults-page.test.tsx`

- [ ] **Step 1: Write the failing test**

Create `frontend/src/settings/vaults-page.test.tsx`:

```tsx
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'

const createMutate = vi.fn()
vi.mock('./vaults/active-vaults-section', () => ({ ActiveVaultsSection: () => <div>active-section</div> }))
vi.mock('./vaults/deleted-vaults-section', () => ({ DeletedVaultsSection: () => <div>deleted-section</div> }))
vi.mock('@/api/queries', () => ({ useCreateVault: () => ({ mutate: createMutate, isPending: false }) }))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import VaultsPage from './vaults-page'

describe('VaultsPage', () => {
  beforeEach(() => vi.clearAllMocks())

  it('renders both sections and a header', () => {
    render(<VaultsPage />)
    expect(screen.getByRole('heading', { name: /vaults/i })).toBeInTheDocument()
    expect(screen.getByText('active-section')).toBeInTheDocument()
    expect(screen.getByText('deleted-section')).toBeInTheDocument()
  })

  it('creates a new vault', async () => {
    render(<VaultsPage />)
    fireEvent.click(screen.getByRole('button', { name: /new vault/i }))
    fireEvent.change(screen.getByLabelText(/vault name/i), { target: { value: 'Research' } })
    fireEvent.click(screen.getByRole('button', { name: /^create$/i }))
    await waitFor(() => expect(createMutate).toHaveBeenCalledWith({ name: 'Research' }, expect.anything()))
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun run test vaults-page`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Implement the page**

Create `frontend/src/settings/vaults-page.tsx`:

```tsx
import { useState } from 'react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { useCreateVault } from '@/api/queries'
import { ActiveVaultsSection } from './vaults/active-vaults-section'
import { DeletedVaultsSection } from './vaults/deleted-vaults-section'

const inputClass =
  'mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export default function VaultsPage() {
  const create = useCreateVault()
  const [open, setOpen] = useState(false)
  const [name, setName] = useState('')

  function submit(e: React.FormEvent) {
    e.preventDefault()
    const next = name.trim()
    if (!next) return
    create.mutate(
      { name: next },
      {
        onSuccess: () => {
          toast.success('Vault created')
          setName('')
          setOpen(false)
        },
        onError: () => toast.error('Could not create vault (limit reached?)'),
      },
    )
  }

  return (
    <article className="space-y-6">
      <header className="flex items-start justify-between">
        <div>
          <h1 className="text-xl font-semibold text-foreground">Vaults</h1>
          <p className="mt-1 text-sm text-muted-foreground">Manage, create, and recover your vaults.</p>
        </div>
        <Button onClick={() => setOpen((o) => !o)}>New vault</Button>
      </header>

      {open && (
        <form className="rounded-lg border border-border bg-card p-4" onSubmit={submit}>
          <label className="block text-sm font-medium text-foreground">
            Vault name
            <input className={inputClass} aria-label="Vault name" value={name} onChange={(e) => setName(e.target.value)} />
          </label>
          <div className="mt-3 flex gap-2">
            <Button type="submit" size="sm" disabled={create.isPending}>
              Create
            </Button>
            <Button type="button" variant="ghost" size="sm" onClick={() => setOpen(false)}>
              Cancel
            </Button>
          </div>
        </form>
      )}

      <ActiveVaultsSection />
      <DeletedVaultsSection />
    </article>
  )
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bun run test vaults-page`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add src/settings/vaults-page.tsx src/settings/vaults-page.test.tsx
git commit -m "feat(frontend): vaults settings page with create"
```

---

### Task 11: Register the section + route

**Files:**
- Modify: `frontend/src/settings/sections.ts`
- Modify: `frontend/src/router.tsx`
- Test: `frontend/src/settings/sections.test.ts` (if present; otherwise add one)

- [ ] **Step 1: Write/extend the failing test**

If `frontend/src/settings/sections.test.ts` exists, add:

```ts
it('includes the Vaults section', () => {
  const labels = buildSettingsSections('clerk', true).map((s) => s.label)
  expect(labels).toContain('Vaults')
})
```

If it does not exist, create `frontend/src/settings/sections.test.ts`:

```ts
import { describe, it, expect } from 'vitest'
import { buildSettingsSections } from './sections'

describe('buildSettingsSections', () => {
  it('includes the Vaults section for clerk + billing', () => {
    const labels = buildSettingsSections('clerk', true).map((s) => s.label)
    expect(labels).toContain('Vaults')
  })

  it('includes the Vaults section for self-host', () => {
    const labels = buildSettingsSections('local', false).map((s) => s.label)
    expect(labels).toContain('Vaults')
  })
})
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun run test sections`
Expected: FAIL — no 'Vaults' label.

- [ ] **Step 3: Register the section**

In `frontend/src/settings/sections.ts`, add Vaults to the always-shown base list:

```typescript
  const sections: SettingsSection[] = [
    { to: 'vaults', label: 'Vaults' },
    { to: 'api-keys', label: 'API Keys' },
  ]
```

- [ ] **Step 4: Add the route**

In `frontend/src/router.tsx`, import the page near the other settings imports:

```typescript
import VaultsPage from '@/settings/vaults-page'
```

Add a child route inside the `/settings` `children` array, alongside `api-keys`:

```typescript
                { path: 'vaults', element: <VaultsPage /> },
```

- [ ] **Step 5: Run to verify it passes**

Run: `bun run test sections`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/settings/sections.ts src/settings/sections.test.ts src/router.tsx
git commit -m "feat(frontend): register Vaults settings section + route"
```

---

### Task 12: Highlight deep-link from email

**Files:**
- Modify: `frontend/src/settings/vaults-page.tsx`
- Modify: `frontend/src/settings/vaults/deleted-vaults-section.tsx`
- Test: extend `frontend/src/settings/vaults/deleted-vaults-section.test.tsx`

- [ ] **Step 1: Write the failing test**

Add to `deleted-vaults-section.test.tsx`:

```tsx
it('highlights the row matching ?highlight=<id>', () => {
  // jsdom: set the query param the component reads
  window.history.pushState({}, '', '/settings/vaults?highlight=5')
  render(<DeletedVaultsSection />)
  expect(screen.getByText('Old').closest('li')).toHaveAttribute('data-highlighted', 'true')
})
```

- [ ] **Step 2: Run to verify it fails**

Run: `bun run test deleted-vaults-section`
Expected: FAIL — no `data-highlighted` attribute.

- [ ] **Step 3: Implement**

In `deleted-vaults-section.tsx`, read the param and tag the row. At the top of `DeletedRow` add:

```tsx
  const highlightId = new URLSearchParams(window.location.search).get('highlight')
  const highlighted = highlightId === String(vault.id)
```

Change the `<li>` opening tag to:

```tsx
    <li
      data-highlighted={highlighted}
      className={`flex items-center justify-between gap-3 py-3 ${highlighted ? 'rounded-md bg-accent/40 ring-1 ring-ring' : ''}`}
    >
```

- [ ] **Step 4: Run to verify it passes**

Run: `bun run test deleted-vaults-section`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/settings/vaults/deleted-vaults-section.tsx src/settings/vaults/deleted-vaults-section.test.tsx
git commit -m "feat(frontend): highlight deep-linked vault row"
```

---

### Task 13: Zero-vault empty state

**Context:** Because deleting the last vault is allowed, the app can have zero active vaults. Audit how the dashboard/note browser consumes the active vault before wiring this in.

**Files:**
- Create: `frontend/src/layout/empty-vault-state.tsx`
- Test: `frontend/src/layout/empty-vault-state.test.tsx`
- Modify: the dashboard/note-browser entry that renders when there is no active vault (identify by reading `src/layout/vault-switcher.tsx`, `src/api/active-vault.ts`, and the `Dashboard` component referenced in `router.tsx`).

- [ ] **Step 1: Read the consumers**

Run: open `src/layout/vault-switcher.tsx`, `src/api/active-vault.ts`, and the `Dashboard` component. Identify where `useVaults()` returns an empty list / `useActiveVaultId()` is null and confirm nothing crashes. Note the render branch to guard.

- [ ] **Step 2: Write the failing test**

Create `frontend/src/layout/empty-vault-state.test.tsx`:

```tsx
import { render, screen } from '@testing-library/react'
import { describe, it, expect } from 'vitest'
import { MemoryRouter } from 'react-router-dom'
import { EmptyVaultState } from './empty-vault-state'

describe('EmptyVaultState', () => {
  it('prompts the user to create a vault and links to settings', () => {
    render(
      <MemoryRouter>
        <EmptyVaultState />
      </MemoryRouter>,
    )
    expect(screen.getByText(/no vaults/i)).toBeInTheDocument()
    const link = screen.getByRole('link', { name: /create a vault/i })
    expect(link).toHaveAttribute('href', '/settings/vaults')
  })
})
```

- [ ] **Step 3: Run to verify it fails**

Run: `bun run test empty-vault-state`
Expected: FAIL — module does not exist.

- [ ] **Step 4: Implement the component**

Create `frontend/src/layout/empty-vault-state.tsx`:

```tsx
import { Link } from 'react-router-dom'
import { Button } from '@/components/ui/button'

export function EmptyVaultState() {
  return (
    <section className="flex flex-col items-center justify-center gap-3 py-16 text-center">
      <h2 className="text-lg font-semibold text-foreground">No vaults</h2>
      <p className="max-w-sm text-sm text-muted-foreground">
        You don't have any vaults right now. Create one to start syncing and searching your notes.
      </p>
      <Button asChild>
        <Link to="/settings/vaults">Create a vault</Link>
      </Button>
    </section>
  )
}
```

> If `Button` does not support `asChild`, render `<Link>` styled as a button (reuse the `buttonVariants` export if present) — keep the accessible name "Create a vault" and `href="/settings/vaults"`.

- [ ] **Step 5: Run to verify it passes**

Run: `bun run test empty-vault-state`
Expected: PASS.

- [ ] **Step 6: Wire it into the no-vault render branch**

In the dashboard/note-browser component identified in Step 1, render `<EmptyVaultState />` when `useVaults()` resolves to an empty array (and there is no active vault) instead of the normal note browser. Keep the change minimal and guard against `undefined` while loading.

- [ ] **Step 7: Typecheck + run the relevant tests**

Run: `bun run build && bun run test empty-vault-state`
Expected: no type errors; test passes.

- [ ] **Step 8: Commit**

```bash
git add src/layout/empty-vault-state.tsx src/layout/empty-vault-state.test.tsx <modified dashboard file>
git commit -m "feat(frontend): zero-vault empty state"
```

---

### Task 14: Full suite + manual smoke

- [ ] **Step 1: Run all backend tests**

Run (repo root): `mix test`
Expected: PASS.

- [ ] **Step 2: Run all frontend tests + typecheck**

Run (`frontend/`): `bun run test && bun run build`
Expected: PASS, no type errors.

- [ ] **Step 3: Manual smoke (dev server)**

Start the app, sign in, go to `/settings/vaults`. Verify: create a vault; rename; set default; delete (type-to-confirm) → appears under Recently deleted with a purge date; restore; delete again then "Delete permanently". With a Free-cap user, confirm Restore is disabled when a replacement exists. Delete the last vault and confirm the empty state renders (no crash). Confirm the deletion email is logged locally (NoOp) or received (if `RESEND_API_KEY` set).

- [ ] **Step 4: Commit any smoke fixes, then finish the branch**

Use `superpowers:finishing-a-development-branch` to open the PR.

---

## Self-Review

**Spec coverage:**
- List trash → Tasks 1, 5. Restore (+cap) → Tasks 2, 5. Purge-now → Tasks 3, 4, 5. Age-guard bug → Task 3. Email (+self-host no-op) → Task 6. Rename/set-default/create → Tasks 7, 8, 10 (reuse `update_vault`/`create_vault`). Two-section page → Tasks 8-10. Type-to-confirm → Task 8 (soft delete) + Task 9 (purge via confirm). Over-cap disable → Task 9. Deep-link highlight → Task 12. Zero-vault state → Task 13. All spec sections map to tasks.
- Out-of-scope items (note counts, archive-forever, bulk, tokened one-click) are correctly absent.

**Placeholder scan:** No TBD/TODO. Two soft spots are explicitly bounded with concrete fallback instructions: the billing-cap hook name (Task 9) and `Button asChild` support (Task 13) and the dashboard wiring point (Task 13 Step 1). These require reading one named file at execution time, not inventing behavior.

**Type consistency:** Hook names (`useDeletedVaults`, `useDeleteVault`, `useRestoreVault`, `usePurgeVault`, `useUpdateVault`, `useCreateVault`) are consistent across Tasks 7-12. `purge_at`/`deleted_at` consistent backend (Task 5) ↔ type (Task 7) ↔ UI (Task 9). `perform_cleanup/3` with `force:` consistent across Tasks 3, 4, 6. Endpoint paths consistent: `POST /vaults/:id/restore`, `POST /vaults/:id/purge`, `GET /vaults?deleted=true`.
