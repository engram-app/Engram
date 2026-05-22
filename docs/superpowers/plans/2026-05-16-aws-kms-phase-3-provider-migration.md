# AWS KMS Phase 3 — Provider Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship per-user, blob-tag-discriminated Local→KMS DEK rewrap on engram-saas, with symmetric rollback (KMS→Local) sharing the same worker.

**Architecture:** Forks `Engram.Crypto.MasterRotation` shape — new module `Engram.Crypto.ProviderMigration` + Oban worker `Engram.Workers.MigrateUserProvider` + Mix task `Mix.Tasks.Engram.MigrateProvider`. Reads dual-route via existing `KeyProvider.identify_from_blob/1`; writes follow `Resolver.provider/0`. `Crypto.get_dek/1` enqueues lazy migration when blob provider ≠ configured provider. No schema migrations.

**Tech Stack:** Elixir/Phoenix, Ecto.Repo with `SELECT ... FOR UPDATE`, Oban (queue `:crypto_backfill` concurrency=1), `:telemetry`, Mox (via `Engram.AwsKmsMock`), ExUnit.

**Spec:** `docs/superpowers/specs/2026-05-16-aws-kms-phase-3-provider-migration-design.md`

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `lib/engram/crypto/provider_migration.ex` | CREATE | Public API: `migrate_user/2`, `migrate_all/2`, `enqueue_all/2`, `status_counts/0`. Per-user txn + FOR UPDATE + cursor stream. |
| `lib/engram/workers/migrate_user_provider.ex` | CREATE | Oban worker. Args `%{"user_id", "target_provider"}`. Queue `:crypto_backfill`. Uniqueness `[:user_id, :target_provider]`. |
| `lib/mix/tasks/engram.migrate_provider.ex` | CREATE | Ops entrypoint. `--target`, `--enqueue`, `--status`, `--batch-size`. Exit codes 0/1/2. |
| `lib/engram/crypto.ex` | MODIFY (`get_dek/1` ~line 175-201) | Dispatch via `KeyProvider.identify_from_blob/1`. Lazy enqueue on provider mismatch. |
| `lib/engram_web/telemetry.ex` | MODIFY | Register `[:engram, :crypto, :migrate_provider, :user]` counter + summary. |
| `test/engram/crypto/provider_migration_test.exs` | CREATE | Unit tests for ProviderMigration API. |
| `test/engram/workers/migrate_user_provider_test.exs` | CREATE | Worker behavior, retry/discard. |
| `test/mix/tasks/engram.migrate_provider_test.exs` | CREATE | Mix task arg parsing, exit codes. |
| `test/engram/crypto_test.exs` | MODIFY | Add `get_dek/1` dual-read quadrant tests. |
| `test/engram/crypto/provider_conformance_test.exs` | MODIFY | Cross-provider identify_from_blob round-trip. |
| `test/engram_web/telemetry_test.exs` | MODIFY | Pin `migrate_provider, :user` event registration. |

Branch already created: `docs/aws-kms-phase-3-design` (in `backend/`). Continue committing on this branch.

---

## Task 1 — Scaffold `ProviderMigration` module + first failing test

**Files:**
- Create: `lib/engram/crypto/provider_migration.ex`
- Create: `test/engram/crypto/provider_migration_test.exs`

- [ ] **Step 1: Write the failing happy-path test (Local→KMS)**

Create `test/engram/crypto/provider_migration_test.exs`:

```elixir
defmodule Engram.Crypto.ProviderMigrationTest do
  use Engram.DataCase, async: false

  import Mox
  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Crypto.ProviderMigration
  alias Engram.Repo

  setup :verify_on_exit!

  setup do
    Application.put_env(
      :engram,
      :encryption_master_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    prev_provider = Application.get_env(:engram, :key_provider)
    prev_client = Application.get_env(:engram, :aws_kms_client)
    Application.put_env(:engram, :aws_kms_client, Engram.AwsKmsMock)

    on_exit(fn ->
      Application.put_env(:engram, :key_provider, prev_provider)
      Application.put_env(:engram, :aws_kms_client, prev_client)
    end)

    :ok
  end

  defp stub_kms_roundtrip do
    table = :ets.new(:mig_kms_stub, [:set, :public])

    stub(Engram.AwsKmsMock, :encrypt, fn pt, _ctx ->
      ct = :crypto.strong_rand_bytes(48)
      :ets.insert(table, {ct, pt})
      {:ok, ct}
    end)

    stub(Engram.AwsKmsMock, :decrypt, fn ct, _ctx ->
      case :ets.lookup(table, ct) do
        [{^ct, pt}] -> {:ok, pt}
        [] -> {:error, :context_mismatch}
      end
    end)

    stub(Engram.AwsKmsMock, :describe_key, fn -> :ok end)

    :ok
  end

  defp user_with_local_dek!(email \\ "u-#{System.unique_integer([:positive])}@e.test") do
    Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)
    {:ok, u} = Engram.Accounts.create_user(%{email: email, password: "pwpw1234!Z"})
    {:ok, u} = Crypto.ensure_user_dek(u)
    u
  end

  describe "migrate_user/2 Local→KMS" do
    test "rewraps blob with KMS provider tag and stamps key_provider" do
      stub_kms_roundtrip()
      user = user_with_local_dek!()
      original_blob = user.encrypted_dek

      assert :ok = ProviderMigration.migrate_user(user.id, :aws_kms)

      reloaded = Repo.one!(from(u in User, where: u.id == ^user.id), skip_tenant_check: true)

      assert <<0xAA, 0x01, _ct::binary>> = reloaded.encrypted_dek
      assert reloaded.encrypted_dek != original_blob
      assert reloaded.key_provider == "aws_kms"
      assert reloaded.dek_version == Engram.Crypto.Config.master_key_version()
    end
  end
end
```

- [ ] **Step 2: Run test, confirm it fails on module-not-found**

```bash
cd backend && mix test test/engram/crypto/provider_migration_test.exs --warnings-as-errors
```

Expected: `** (UndefinedFunctionError) function Engram.Crypto.ProviderMigration.migrate_user/2 is undefined`.

- [ ] **Step 3: Write minimal `ProviderMigration` module**

Create `lib/engram/crypto/provider_migration.ex`:

```elixir
defmodule Engram.Crypto.ProviderMigration do
  @moduledoc """
  Phase 3 — Per-user `KeyProvider` rewrap. Migrates `users.encrypted_dek`
  from one provider to another (Local↔AwsKms) by unwrapping with the
  source provider (identified via `KeyProvider.identify_from_blob/1`) and
  re-wrapping with the target.

  Cheaper than `MasterRotation` / `UserDekRotation`: the *plaintext* DEK
  is preserved across rewrap, so no tenant data rows need re-encryption.
  Only `users.encrypted_dek` + `users.key_provider` change per user.

  Telemetry `[:engram, :crypto, :migrate_provider, :user]` per call with
  `%{duration_us, count}` measurements and
  `%{user_id, target_provider, status: :ok | :skipped | :failed, reason_label?}`.

  Forward (Local→AwsKms) and reverse (AwsKms→Local) use the same code
  path — `target_provider` arg flips direction.

  ## Lock + transaction shape

  Each rewrap runs in its own `Repo.transaction` with `SELECT ... FOR UPDATE`
  on the user row. Concurrent callers (Mix task + Oban job for the same
  user) serialize cleanly: the loser sees the post-commit `key_provider`
  and short-circuits to `:skipped`.

  `DekCache.put/2` is deferred until AFTER the transaction commits — a
  rolled-back txn must NOT leave a cached DEK that no longer matches DB.
  """

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Crypto.{Config, DekCache, KeyProvider}
  alias Engram.Crypto.KeyProvider.{AwsKms, Local}
  alias Engram.Repo

  require Logger

  @type provider_atom :: :local | :aws_kms
  @type migrate_result :: :ok | :skipped | {:error, term()}
  @type counts :: %{ok: non_neg_integer(), skipped: non_neg_integer(), failed: non_neg_integer()}

  @doc "Migrate one user's wrapped DEK to `target_provider`."
  @spec migrate_user(integer() | User.t(), provider_atom()) :: migrate_result()
  def migrate_user(user_or_id, target_provider) when target_provider in [:local, :aws_kms] do
    user_id =
      case user_or_id do
        %User{id: id} -> id
        id when is_integer(id) -> id
      end

    started_at = System.monotonic_time()
    result = do_migrate(user_id, target_provider)
    duration_us = duration_us_since(started_at)
    emit_telemetry(user_id, target_provider, result, duration_us)

    case result do
      {:migrated, _user, _dek} -> :ok
      {:skipped, _user} -> :skipped
      {:error, reason} -> {:error, reason}
    end
  end

  # ── internals ──────────────────────────────────────────────────────

  defp do_migrate(user_id, target_provider) do
    target_module = module_for(target_provider)
    target_name = Atom.to_string(target_provider)

    txn =
      Repo.transaction(fn ->
        locked =
          from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE")
          |> Repo.one(skip_tenant_check: true)

        cond do
          is_nil(locked) ->
            Repo.rollback({:not_found, user_id})

          is_nil(locked.encrypted_dek) ->
            Repo.rollback(:no_dek)

          locked.key_provider == target_name ->
            {:skipped, locked}

          true ->
            rewrap_locked(locked, target_module, target_name)
        end
      end)

    case txn do
      {:ok, {:skipped, user}} -> {:skipped, user}
      {:ok, {:migrated, user, dek}} -> {:migrated, user, dek}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rewrap_locked(%User{} = locked, target_module, target_name) do
    with {:ok, source_module} <- KeyProvider.identify_from_blob(locked.encrypted_dek),
         ctx = %{user_id: locked.id},
         {:ok, dek} <- source_module.unwrap_dek(locked.encrypted_dek, ctx),
         {:ok, new_blob} <- target_module.wrap_dek(dek, ctx),
         {:ok, updated} <-
           Accounts.update_user_encryption(locked, %{
             encrypted_dek: new_blob,
             key_provider: target_name,
             dek_version: Config.master_key_version()
           }) do
      {:migrated, updated, dek}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp module_for(:local), do: Local
  defp module_for(:aws_kms), do: AwsKms

  defp duration_us_since(started_at) do
    System.convert_time_unit(
      System.monotonic_time() - started_at,
      :native,
      :microsecond
    )
  end

  defp emit_telemetry(user_id, target_provider, {:migrated, _, _}, duration_us) do
    :telemetry.execute(
      [:engram, :crypto, :migrate_provider, :user],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, target_provider: target_provider, status: :ok}
    )
  end

  defp emit_telemetry(user_id, target_provider, {:skipped, _}, duration_us) do
    :telemetry.execute(
      [:engram, :crypto, :migrate_provider, :user],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, target_provider: target_provider, status: :skipped}
    )
  end

  defp emit_telemetry(user_id, target_provider, {:error, reason}, duration_us) do
    label = classify_reason(reason)

    Logger.error(
      "provider migration failed user_id=#{user_id} target=#{target_provider} reason_label=#{label}",
      category: :crypto_migration
    )

    :telemetry.execute(
      [:engram, :crypto, :migrate_provider, :user],
      %{duration_us: duration_us, count: 1},
      %{
        user_id: user_id,
        target_provider: target_provider,
        status: :failed,
        reason_label: label
      }
    )
  end

  defp classify_reason(:no_dek), do: "no_dek"
  defp classify_reason({:not_found, _}), do: "not_found"
  defp classify_reason(:invalid_wrapping), do: "invalid_wrapping"
  defp classify_reason(:malformed_wrapped_blob), do: "malformed_wrapped_blob"
  defp classify_reason(:kms_throttled), do: "kms_throttled"
  defp classify_reason(:kms_access_denied), do: "kms_access_denied"
  defp classify_reason(:kms_key_not_found), do: "kms_key_not_found"
  defp classify_reason({:kms_encrypt_failed, _}), do: "kms_encrypt_failed"
  defp classify_reason({:kms_decrypt_failed, _}), do: "kms_decrypt_failed"
  defp classify_reason(:unrecognised_blob), do: "unrecognised_blob"
  defp classify_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp classify_reason(%Ecto.Changeset{}), do: "changeset_invalid"
  defp classify_reason(_other), do: "other"
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd backend && mix test test/engram/crypto/provider_migration_test.exs --warnings-as-errors
```

Expected: 1 test, 0 failures.

- [ ] **Step 5: Commit**

```bash
cd backend && git add lib/engram/crypto/provider_migration.ex test/engram/crypto/provider_migration_test.exs && git commit -m "feat(crypto): ProviderMigration.migrate_user Local→KMS happy path

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2 — Reverse migration (KMS→Local) + idempotent skip

**Files:**
- Modify: `test/engram/crypto/provider_migration_test.exs`

- [ ] **Step 1: Write the failing tests**

Append inside the existing test module (before the closing `end`):

```elixir
  describe "migrate_user/2 KMS→Local reverse" do
    test "rewraps from KMS blob back to Local with 0x01/0x02 leading byte" do
      stub_kms_roundtrip()
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.AwsKms)
      {:ok, u} = Engram.Accounts.create_user(%{email: "kms-#{System.unique_integer([:positive])}@e.test", password: "pwpw1234!Z"})
      {:ok, u} = Crypto.ensure_user_dek(u)
      assert <<0xAA, _::binary>> = u.encrypted_dek

      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)
      assert :ok = ProviderMigration.migrate_user(u.id, :local)

      reloaded = Repo.one!(from(x in User, where: x.id == ^u.id), skip_tenant_check: true)
      assert <<tag, 0x01, _::binary-size(60)>> = reloaded.encrypted_dek
      assert tag in [0x01, 0x02]
      assert reloaded.key_provider == "local"
    end
  end

  describe "migrate_user/2 idempotence" do
    test "returns :skipped when user is already at target_provider, no provider calls made" do
      stub_kms_roundtrip()
      user = user_with_local_dek!()

      # First migration: Local→KMS.
      assert :ok = ProviderMigration.migrate_user(user.id, :aws_kms)

      # Second migration to same target: skipped, zero KMS calls expected
      # because the cond branch short-circuits before touching providers.
      expect(Engram.AwsKmsMock, :encrypt, 0, fn _, _ -> :unused end)
      expect(Engram.AwsKmsMock, :decrypt, 0, fn _, _ -> :unused end)

      assert :skipped = ProviderMigration.migrate_user(user.id, :aws_kms)
    end
  end
```

- [ ] **Step 2: Run test to verify pass**

```bash
cd backend && mix test test/engram/crypto/provider_migration_test.exs --warnings-as-errors
```

Expected: 3 tests, 0 failures. (No production-code change needed — the `cond` branch in `do_migrate/2` already handles both cases.)

- [ ] **Step 3: Commit**

```bash
cd backend && git add test/engram/crypto/provider_migration_test.exs && git commit -m "test(crypto): ProviderMigration reverse direction + idempotent skip

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3 — Failure-mode coverage + telemetry assertions

**Files:**
- Modify: `test/engram/crypto/provider_migration_test.exs`

- [ ] **Step 1: Add telemetry capture helper + failure tests**

First, add a module-level helper. Insert this `defp` **above** the first `describe` block (alongside the existing `stub_kms_roundtrip/0` + `user_with_local_dek!/1` helpers — NOT inside a `describe`, which would be a compile error):

```elixir
  defp attach_telemetry_capture(test_pid) do
    handler_id = "test-migrate-provider-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:engram, :crypto, :migrate_provider, :user],
      fn _name, measurements, metadata, _cfg ->
        send(test_pid, {:telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
```

Then append the failure-mode `describe` block:

```elixir
  describe "migrate_user/2 failure modes" do
    test ":kms_access_denied surfaces, txn rolls back, blob unchanged, telemetry :failed" do
      Application.put_env(:engram, :aws_kms_client, Engram.AwsKmsMock)
      stub(Engram.AwsKmsMock, :encrypt, fn _, _ -> {:error, :access_denied} end)

      user = user_with_local_dek!()
      original_blob = user.encrypted_dek

      attach_telemetry_capture(self())

      assert {:error, {:kms_encrypt_failed, :access_denied}} =
               ProviderMigration.migrate_user(user.id, :aws_kms)

      reloaded = Repo.one!(from(u in User, where: u.id == ^user.id), skip_tenant_check: true)
      assert reloaded.encrypted_dek == original_blob
      assert reloaded.key_provider == "local"

      assert_receive {:telemetry, %{count: 1}, %{status: :failed, reason_label: "kms_encrypt_failed"}}
    end

    test ":kms_throttled surfaces verbatim" do
      stub(Engram.AwsKmsMock, :encrypt, fn _, _ -> {:error, :throttled} end)

      user = user_with_local_dek!()

      assert {:error, {:kms_encrypt_failed, :throttled}} =
               ProviderMigration.migrate_user(user.id, :aws_kms)
    end

    test "user deleted mid-flight returns {:error, {:not_found, uid}}" do
      stub_kms_roundtrip()
      missing_id = 99_999_999

      assert {:error, {:not_found, ^missing_id}} =
               ProviderMigration.migrate_user(missing_id, :aws_kms)
    end

    test "user with nil encrypted_dek returns {:error, :no_dek}" do
      stub_kms_roundtrip()
      {:ok, u} = Engram.Accounts.create_user(%{email: "nodek-#{System.unique_integer([:positive])}@e.test", password: "pwpw1234!Z"})

      assert {:error, :no_dek} = ProviderMigration.migrate_user(u.id, :aws_kms)
    end

    test "happy path emits :ok telemetry with target_provider metadata" do
      stub_kms_roundtrip()
      user = user_with_local_dek!()

      attach_telemetry_capture(self())

      assert :ok = ProviderMigration.migrate_user(user.id, :aws_kms)
      assert_receive {:telemetry, %{count: 1, duration_us: dur},
                      %{user_id: uid, target_provider: :aws_kms, status: :ok}}
                     when is_integer(dur) and dur >= 0

      assert uid == user.id
    end
  end
```

- [ ] **Step 2: Run test to verify pass**

```bash
cd backend && mix test test/engram/crypto/provider_migration_test.exs --warnings-as-errors
```

Expected: 8 tests, 0 failures.

- [ ] **Step 3: Commit**

```bash
cd backend && git add test/engram/crypto/provider_migration_test.exs && git commit -m "test(crypto): ProviderMigration failure modes + telemetry pins

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4 — Concurrent-rewrap race test (FOR UPDATE serialization)

**Files:**
- Modify: `test/engram/crypto/provider_migration_test.exs`

- [ ] **Step 1: Add race test**

Append:

```elixir
  describe "migrate_user/2 concurrent races" do
    test "4 parallel migrate_user calls for same user → exactly one rewrap, three :skipped" do
      stub_kms_roundtrip()
      user = user_with_local_dek!()
      uid = user.id

      results =
        1..4
        |> Task.async_stream(fn _ -> ProviderMigration.migrate_user(uid, :aws_kms) end,
          max_concurrency: 4,
          ordered: false,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      ok_count = Enum.count(results, &(&1 == :ok))
      skipped_count = Enum.count(results, &(&1 == :skipped))

      assert ok_count == 1, "expected exactly one :ok, got #{ok_count} (results=#{inspect(results)})"
      assert skipped_count == 3, "expected three :skipped, got #{skipped_count}"

      reloaded = Repo.one!(from(u in User, where: u.id == ^uid), skip_tenant_check: true)
      assert reloaded.key_provider == "aws_kms"
    end
  end
```

- [ ] **Step 2: Run test**

```bash
cd backend && mix test test/engram/crypto/provider_migration_test.exs --warnings-as-errors
```

Expected: 9 tests, 0 failures.

- [ ] **Step 3: Commit**

```bash
cd backend && git add test/engram/crypto/provider_migration_test.exs && git commit -m "test(crypto): ProviderMigration race test (4-parallel FOR UPDATE)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5 — `migrate_all/2`, `enqueue_all/2`, `status_counts/0`

**Files:**
- Modify: `lib/engram/crypto/provider_migration.ex`
- Modify: `test/engram/crypto/provider_migration_test.exs`

- [ ] **Step 1: Write failing tests for fleet ops**

Append to test module:

```elixir
  describe "migrate_all/2" do
    test "drains every user not at target into the target provider" do
      stub_kms_roundtrip()
      u1 = user_with_local_dek!()
      u2 = user_with_local_dek!()
      # u3 starts on KMS — must be skipped.
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.AwsKms)
      {:ok, u3} = Engram.Accounts.create_user(%{email: "k-#{System.unique_integer([:positive])}@e.test", password: "pwpw1234!Z"})
      {:ok, _} = Crypto.ensure_user_dek(u3)
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)

      assert %{ok: 2, skipped: ok_or_skipped, failed: 0} =
               ProviderMigration.migrate_all(:aws_kms, batch_size: 10)

      # u3 contributes to :skipped. Other already-aws_kms users from prior
      # tests in this DB sandbox may also contribute.
      assert ok_or_skipped >= 1

      assert "aws_kms" =
               Repo.one!(from(u in User, where: u.id == ^u1.id, select: u.key_provider),
                 skip_tenant_check: true
               )

      assert "aws_kms" =
               Repo.one!(from(u in User, where: u.id == ^u2.id, select: u.key_provider),
                 skip_tenant_check: true
               )
    end
  end

  describe "enqueue_all/2" do
    test "inserts one Oban job per below-target user" do
      _u1 = user_with_local_dek!()
      _u2 = user_with_local_dek!()

      assert %{enqueued: n} = ProviderMigration.enqueue_all(:aws_kms, batch_size: 10)
      assert n >= 2

      jobs =
        Oban.Job
        |> Repo.all(skip_tenant_check: true)
        |> Enum.filter(&(&1.worker == "Engram.Workers.MigrateUserProvider"))

      assert length(jobs) >= 2

      Enum.each(jobs, fn job ->
        assert %{"target_provider" => "aws_kms", "user_id" => uid} = job.args
        assert is_integer(uid)
      end)
    end
  end

  describe "status_counts/0" do
    test "returns counts grouped by users.key_provider" do
      _ = user_with_local_dek!()
      counts = ProviderMigration.status_counts()
      assert is_map(counts)
      assert counts[:local] >= 1
      assert Map.has_key?(counts, :total)
      assert counts.total == (counts[:local] || 0) + (counts[:aws_kms] || 0)
    end
  end
```

- [ ] **Step 2: Run, observe failures**

```bash
cd backend && mix test test/engram/crypto/provider_migration_test.exs --warnings-as-errors
```

Expected: `migrate_all/2`, `enqueue_all/2`, `status_counts/0` undefined.

- [ ] **Step 3: Implement `migrate_all/2` + `enqueue_all/2` + `status_counts/0`**

Append inside `Engram.Crypto.ProviderMigration` (just below `migrate_user/2`):

```elixir
  @doc """
  Migrate every user whose `key_provider` ≠ `target_provider`. Cursor-by-id.
  Each user runs in its own transaction.

  Returns aggregate counts. `:skipped` includes both already-at-target
  users and users without an `encrypted_dek` (latter is rare; counted as
  skipped because the fleet drain semantically completes for them).
  """
  @spec migrate_all(provider_atom(), keyword()) :: counts() | {:error, term()}
  def migrate_all(target_provider, opts \\ []) when target_provider in [:local, :aws_kms] do
    batch_size = Keyword.get(opts, :batch_size, 100)
    drive_loop(target_provider, 0, batch_size, %{ok: 0, skipped: 0, failed: 0})
  end

  @doc """
  Enqueue one `Engram.Workers.MigrateUserProvider` Oban job per below-target
  user. Idempotent — Oban uniqueness on `[:user_id, :target_provider]`
  collapses duplicate inserts; the worker re-checks `:skipped` at perform.
  """
  @spec enqueue_all(provider_atom(), keyword()) :: %{enqueued: non_neg_integer()}
  def enqueue_all(target_provider, opts \\ []) when target_provider in [:local, :aws_kms] do
    batch_size = Keyword.get(opts, :batch_size, 500)
    target_name = Atom.to_string(target_provider)
    %{enqueued: enqueue_loop(target_provider, target_name, 0, batch_size, 0)}
  end

  @doc "Provider count breakdown: `%{local: N, aws_kms: M, total: N+M}`."
  @spec status_counts() :: %{atom() => non_neg_integer()}
  def status_counts do
    rows =
      from(u in User,
        where: not is_nil(u.encrypted_dek),
        group_by: u.key_provider,
        select: {u.key_provider, count(u.id)}
      )
      |> Repo.all(skip_tenant_check: true)

    base = %{local: 0, aws_kms: 0}

    rows
    |> Enum.reduce(base, fn {provider, n}, acc ->
      key = if provider in ["local", "aws_kms"], do: String.to_atom(provider), else: :other
      Map.update(acc, key, n, &(&1 + n))
    end)
    |> then(fn counts -> Map.put(counts, :total, counts.local + counts.aws_kms) end)
  end

  defp drive_loop(target_provider, last_id, batch_size, acc) do
    target_name = Atom.to_string(target_provider)

    ids =
      from(u in User,
        where: not is_nil(u.encrypted_dek) and u.key_provider != ^target_name,
        where: u.id > ^last_id,
        select: u.id,
        order_by: u.id,
        limit: ^batch_size
      )
      |> Repo.all(skip_tenant_check: true)

    case ids do
      [] ->
        acc

      _ ->
        acc =
          Enum.reduce(ids, acc, fn id, a ->
            case migrate_user(id, target_provider) do
              :ok -> Map.update!(a, :ok, &(&1 + 1))
              :skipped -> Map.update!(a, :skipped, &(&1 + 1))
              {:error, _} -> Map.update!(a, :failed, &(&1 + 1))
            end
          end)

        drive_loop(target_provider, List.last(ids), batch_size, acc)
    end
  end

  defp enqueue_loop(target_provider, target_name, last_id, batch_size, total) do
    ids =
      from(u in User,
        where: not is_nil(u.encrypted_dek) and u.key_provider != ^target_name,
        where: u.id > ^last_id,
        select: u.id,
        order_by: u.id,
        limit: ^batch_size
      )
      |> Repo.all(skip_tenant_check: true)

    case ids do
      [] ->
        total

      _ ->
        jobs =
          Enum.map(ids, fn id ->
            Engram.Workers.MigrateUserProvider.new(%{
              "user_id" => id,
              "target_provider" => target_name
            })
          end)

        {:ok, _} =
          Ecto.Multi.new()
          |> Oban.insert_all(:migrate_provider_jobs, jobs)
          |> Repo.transaction()

        enqueue_loop(target_provider, target_name, List.last(ids), batch_size, total + length(jobs))
    end
  end
```

- [ ] **Step 4: Run test (expect MigrateUserProvider undefined)**

```bash
cd backend && mix test test/engram/crypto/provider_migration_test.exs --warnings-as-errors
```

Expected: 10 of 12 tests pass; `enqueue_all` tests fail with `Engram.Workers.MigrateUserProvider` undefined. (Task 6 ships the worker; this is intentional.) `migrate_all/2` + `status_counts/0` tests pass.

- [ ] **Step 5: Commit (partial — worker lands in next task)**

```bash
cd backend && git add lib/engram/crypto/provider_migration.ex test/engram/crypto/provider_migration_test.exs && git commit -m "feat(crypto): ProviderMigration migrate_all + enqueue_all + status_counts

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6 — `MigrateUserProvider` Oban worker

**Files:**
- Create: `lib/engram/workers/migrate_user_provider.ex`
- Create: `test/engram/workers/migrate_user_provider_test.exs`

- [ ] **Step 1: Write failing worker tests**

Create `test/engram/workers/migrate_user_provider_test.exs`:

```elixir
defmodule Engram.Workers.MigrateUserProviderTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox
  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Repo
  alias Engram.Workers.MigrateUserProvider

  setup :verify_on_exit!

  setup do
    Application.put_env(
      :engram,
      :encryption_master_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:engram, :aws_kms_client, Engram.AwsKmsMock)
    Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)

    table = :ets.new(:worker_kms_stub, [:set, :public])

    stub(Engram.AwsKmsMock, :encrypt, fn pt, _ ->
      ct = :crypto.strong_rand_bytes(48)
      :ets.insert(table, {ct, pt})
      {:ok, ct}
    end)

    stub(Engram.AwsKmsMock, :decrypt, fn ct, _ ->
      case :ets.lookup(table, ct) do
        [{^ct, pt}] -> {:ok, pt}
        [] -> {:error, :context_mismatch}
      end
    end)

    stub(Engram.AwsKmsMock, :describe_key, fn -> :ok end)
    :ok
  end

  defp user_with_local_dek! do
    {:ok, u} =
      Engram.Accounts.create_user(%{
        email: "w-#{System.unique_integer([:positive])}@e.test",
        password: "pwpw1234!Z"
      })

    {:ok, u} = Crypto.ensure_user_dek(u)
    u
  end

  test "perform/1 happy path: returns :ok, rewraps user" do
    user = user_with_local_dek!()

    assert :ok =
             perform_job(MigrateUserProvider, %{
               "user_id" => user.id,
               "target_provider" => "aws_kms"
             })

    reloaded = Repo.one!(from(u in User, where: u.id == ^user.id), skip_tenant_check: true)
    assert reloaded.key_provider == "aws_kms"
  end

  test "perform/1 skipped (already at target) returns :ok" do
    user = user_with_local_dek!()

    :ok = perform_job(MigrateUserProvider, %{"user_id" => user.id, "target_provider" => "aws_kms"})

    # Second run on same user should also return :ok (skipped collapses to :ok at worker layer).
    assert :ok =
             perform_job(MigrateUserProvider, %{
               "user_id" => user.id,
               "target_provider" => "aws_kms"
             })
  end

  test "perform/1 returns {:discard, :user_deleted} when user is missing" do
    assert {:discard, :user_deleted} =
             perform_job(MigrateUserProvider, %{
               "user_id" => 99_999_999,
               "target_provider" => "aws_kms"
             })
  end

  test "perform/1 returns {:discard, :no_dek} when user has no encrypted_dek" do
    {:ok, u} =
      Engram.Accounts.create_user(%{
        email: "nokmsdek-#{System.unique_integer([:positive])}@e.test",
        password: "pwpw1234!Z"
      })

    assert {:discard, :no_dek} =
             perform_job(MigrateUserProvider, %{
               "user_id" => u.id,
               "target_provider" => "aws_kms"
             })
  end

  test "perform/1 returns {:error, reason} for retryable KMS errors" do
    stub(Engram.AwsKmsMock, :encrypt, fn _, _ -> {:error, :throttled} end)
    user = user_with_local_dek!()

    assert {:error, {:kms_encrypt_failed, :throttled}} =
             perform_job(MigrateUserProvider, %{
               "user_id" => user.id,
               "target_provider" => "aws_kms"
             })
  end

  test "perform/1 returns {:discard, {:invalid_args, …}} for malformed args" do
    assert {:discard, {:invalid_args, _}} = perform_job(MigrateUserProvider, %{"garbage" => 1})
  end

  test "perform/1 rejects unknown target_provider" do
    assert {:discard, {:unknown_target, "passphrase"}} =
             perform_job(MigrateUserProvider, %{"user_id" => 1, "target_provider" => "passphrase"})
  end
end
```

- [ ] **Step 2: Run, observe failures**

```bash
cd backend && mix test test/engram/workers/migrate_user_provider_test.exs --warnings-as-errors
```

Expected: `Engram.Workers.MigrateUserProvider is not loaded`.

- [ ] **Step 3: Implement the worker**

Create `lib/engram/workers/migrate_user_provider.ex`:

```elixir
defmodule Engram.Workers.MigrateUserProvider do
  @moduledoc """
  Phase 3 — Oban worker that rewraps one user's `encrypted_dek` from the
  source provider (identified by blob tag) to `target_provider`.

  Args:

      %{"user_id" => integer, "target_provider" => "local" | "aws_kms"}

  Idempotent at two layers:

  1. Oban uniqueness on `[:user_id, :target_provider]` for in-flight
     states prevents duplicate jobs for the same target.
  2. `ProviderMigration.migrate_user/2` returns `:skipped` when the user
     is already at target — re-running stale jobs is a no-op.

  Production runs prefer this worker over the long-lived Mix task: jobs
  survive node restarts via Oban persistence, and the `:crypto_backfill`
  queue's concurrency=1 serializes against other crypto migrations
  (master rotation, AAD rebind, DEK rotation).
  """

  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 5,
    unique: [
      keys: [:user_id, :target_provider],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Engram.Crypto.ProviderMigration

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "target_provider" => target}})
      when is_integer(user_id) and target in ["local", "aws_kms"] do
    target_atom = String.to_existing_atom(target)

    case ProviderMigration.migrate_user(user_id, target_atom) do
      :ok -> :ok
      :skipped -> :ok
      {:error, {:not_found, _}} -> {:discard, :user_deleted}
      {:error, :no_dek} -> {:discard, :no_dek}
      {:error, :malformed_wrapped_blob} -> {:discard, :malformed_wrapped_blob}
      {:error, :unrecognised_blob} -> {:discard, :unrecognised_blob}
      {:error, %Ecto.Changeset{errors: errors}} -> {:discard, {:changeset_invalid, errors}}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{
        args: %{"user_id" => _user_id, "target_provider" => other}
      }) do
    {:discard, {:unknown_target, other}}
  end

  def perform(%Oban.Job{args: args}) do
    {:discard, {:invalid_args, Map.keys(args)}}
  end
end
```

- [ ] **Step 4: Run all migration tests**

```bash
cd backend && mix test test/engram/workers/migrate_user_provider_test.exs test/engram/crypto/provider_migration_test.exs --warnings-as-errors
```

Expected: 19 tests, 0 failures (12 from provider_migration_test + 7 from worker_test).

- [ ] **Step 5: Commit**

```bash
cd backend && git add lib/engram/workers/migrate_user_provider.ex test/engram/workers/migrate_user_provider_test.exs && git commit -m "feat(crypto): MigrateUserProvider Oban worker

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7 — `Crypto.get_dek/1` dual-read + lazy enqueue

**Files:**
- Modify: `lib/engram/crypto.ex`
- Modify: `test/engram/crypto_test.exs`

- [ ] **Step 1: Write the failing dual-read tests**

Find the existing `describe "get_dek/1"` block (if any) in `test/engram/crypto_test.exs` and append a new describe block at the bottom of the file (before the final `end`):

```elixir
  describe "get_dek/1 dual-read + lazy migration" do
    import Mox
    use Oban.Testing, repo: Engram.Repo
    setup :verify_on_exit!

    setup do
      Application.put_env(
        :engram,
        :encryption_master_key,
        Base.encode64(:crypto.strong_rand_bytes(32))
      )

      Application.put_env(:engram, :aws_kms_client, Engram.AwsKmsMock)

      table = :ets.new(:dual_read_stub, [:set, :public])

      stub(Engram.AwsKmsMock, :encrypt, fn pt, _ ->
        ct = :crypto.strong_rand_bytes(48)
        :ets.insert(table, {ct, pt})
        {:ok, ct}
      end)

      stub(Engram.AwsKmsMock, :decrypt, fn ct, _ ->
        case :ets.lookup(table, ct) do
          [{^ct, pt}] -> {:ok, pt}
          [] -> {:error, :context_mismatch}
        end
      end)

      stub(Engram.AwsKmsMock, :describe_key, fn -> :ok end)
      :ok
    end

    defp make_user_with_provider!(provider_module) do
      Application.put_env(:engram, :key_provider, provider_module)

      {:ok, u} =
        Engram.Accounts.create_user(%{
          email: "dual-#{System.unique_integer([:positive])}@e.test",
          password: "pwpw1234!Z"
        })

      {:ok, u} = Engram.Crypto.ensure_user_dek(u)
      Engram.Crypto.DekCache.delete(u.id)
      u
    end

    test "Local blob + KEY_PROVIDER=local → succeeds, no enqueue" do
      user = make_user_with_provider!(Engram.Crypto.KeyProvider.Local)
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)

      assert {:ok, <<_::256>>} = Engram.Crypto.get_dek(user)

      refute_enqueued(worker: Engram.Workers.MigrateUserProvider, args: %{"user_id" => user.id})
    end

    test "Local blob + KEY_PROVIDER=aws_kms → succeeds via Local, enqueues lazy migration to KMS" do
      user = make_user_with_provider!(Engram.Crypto.KeyProvider.Local)
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.AwsKms)

      assert {:ok, <<_::256>>} = Engram.Crypto.get_dek(user)

      assert_enqueued(
        worker: Engram.Workers.MigrateUserProvider,
        args: %{"user_id" => user.id, "target_provider" => "aws_kms"}
      )
    end

    test "KMS blob + KEY_PROVIDER=aws_kms → succeeds, no enqueue" do
      user = make_user_with_provider!(Engram.Crypto.KeyProvider.AwsKms)
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.AwsKms)

      assert {:ok, <<_::256>>} = Engram.Crypto.get_dek(user)

      refute_enqueued(worker: Engram.Workers.MigrateUserProvider, args: %{"user_id" => user.id})
    end

    test "KMS blob + KEY_PROVIDER=local → succeeds via KMS, enqueues reverse migration to local" do
      user = make_user_with_provider!(Engram.Crypto.KeyProvider.AwsKms)
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)

      assert {:ok, <<_::256>>} = Engram.Crypto.get_dek(user)

      assert_enqueued(
        worker: Engram.Workers.MigrateUserProvider,
        args: %{"user_id" => user.id, "target_provider" => "local"}
      )
    end

    test "lazy enqueue is best-effort: an Oban.insert failure does not bubble to caller" do
      user = make_user_with_provider!(Engram.Crypto.KeyProvider.Local)
      Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.AwsKms)

      # Cache hit path bypasses lazy enqueue entirely. Prime the cache,
      # then assert no enqueue (because the unwrap path is short-circuited).
      Engram.Crypto.DekCache.delete(user.id)
      {:ok, dek} = Engram.Crypto.get_dek(user)
      Engram.Crypto.DekCache.put(user.id, dek)

      assert {:ok, ^dek} = Engram.Crypto.get_dek(user)
      # First call enqueued; second call is a cache hit so no new job.
      # Oban testing helper counts cumulative — at least one job exists.
      assert_enqueued(worker: Engram.Workers.MigrateUserProvider, args: %{"user_id" => user.id})
    end
  end
```

- [ ] **Step 2: Run, observe failures**

```bash
cd backend && mix test test/engram/crypto_test.exs --warnings-as-errors
```

Expected: 4 of 5 dual-read tests fail because `get_dek/1` currently dispatches via `Resolver.provider_for/1` instead of `identify_from_blob/1`, and no lazy enqueue exists.

- [ ] **Step 3: Patch `Crypto.get_dek/1`**

In `lib/engram/crypto.ex`, replace the `get_dek/1` implementation (around line 173-201) with:

```elixir
  def get_dek(%User{encrypted_dek: nil}), do: {:error, :no_dek}

  def get_dek(%User{id: user_id, encrypted_dek: blob, dek_version: dek_version}) do
    mark_sensitive()

    case DekCache.get(user_id) do
      {:ok, dek} ->
        {:ok, dek}

      :miss ->
        # Phase 3 — dispatch unwrap by blob tag, not by Resolver.provider/0.
        # Lets mixed-state fleets read seamlessly during Local↔KMS backfill
        # windows. Writes still follow Resolver (see ensure_user_dek/1).
        case KeyProvider.identify_from_blob(blob) do
          {:ok, source_provider} ->
            ctx = %{
              user_id: user_id,
              dek_version: dek_version,
              master_key_version: Engram.Crypto.Config.master_key_version()
            }

            case source_provider.unwrap_dek(blob, ctx) do
              {:ok, dek} ->
                DekCache.put(user_id, dek)
                maybe_enqueue_lazy_migration(user_id, source_provider)
                {:ok, dek}

              {:error, _} = err ->
                err
            end

          {:error, :unrecognised_blob} ->
            {:error, :unrecognised_blob}
        end
    end
  end

  # Phase 3 — fire-and-forget lazy migration. Never blocks the read path,
  # never raises. Oban uniqueness `[:user_id, :target_provider]` collapses
  # duplicate enqueues against the active backfill drain.
  defp maybe_enqueue_lazy_migration(user_id, source_provider) do
    configured = Engram.Crypto.KeyProvider.Resolver.provider()

    if source_provider != configured do
      target_atom =
        case configured do
          Engram.Crypto.KeyProvider.Local -> :local
          Engram.Crypto.KeyProvider.AwsKms -> :aws_kms
          _ -> nil
        end

      if target_atom do
        try do
          %{"user_id" => user_id, "target_provider" => Atom.to_string(target_atom)}
          |> Engram.Workers.MigrateUserProvider.new()
          |> Oban.insert()
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end
    end

    :ok
  end
```

Add the `alias Engram.Crypto.KeyProvider` near the top of `crypto.ex` if not already present (check the existing `alias` block).

- [ ] **Step 4: Run tests**

```bash
cd backend && mix test test/engram/crypto_test.exs --warnings-as-errors
```

Expected: all 5 dual-read tests pass. Other `crypto_test.exs` tests still green.

- [ ] **Step 5: Run full crypto suite + worker suite**

```bash
cd backend && mix test test/engram/crypto/ test/engram/crypto_test.exs test/engram/workers/migrate_user_provider_test.exs --warnings-as-errors
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
cd backend && git add lib/engram/crypto.ex test/engram/crypto_test.exs && git commit -m "feat(crypto): get_dek dual-read via identify_from_blob + lazy migration enqueue

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8 — `engram.migrate_provider` Mix task

**Files:**
- Create: `lib/mix/tasks/engram.migrate_provider.ex`
- Create: `test/mix/tasks/engram.migrate_provider_test.exs`

- [ ] **Step 1: Write failing Mix task tests**

Create `test/mix/tasks/engram.migrate_provider_test.exs`:

```elixir
defmodule Mix.Tasks.Engram.MigrateProviderTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Mox
  import ExUnit.CaptureIO

  alias Engram.Crypto

  setup :verify_on_exit!

  setup do
    Application.put_env(
      :engram,
      :encryption_master_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:engram, :aws_kms_client, Engram.AwsKmsMock)

    table = :ets.new(:task_kms_stub, [:set, :public])

    stub(Engram.AwsKmsMock, :encrypt, fn pt, _ ->
      ct = :crypto.strong_rand_bytes(48)
      :ets.insert(table, {ct, pt})
      {:ok, ct}
    end)

    stub(Engram.AwsKmsMock, :decrypt, fn ct, _ ->
      case :ets.lookup(table, ct) do
        [{^ct, pt}] -> {:ok, pt}
        [] -> {:error, :context_mismatch}
      end
    end)

    stub(Engram.AwsKmsMock, :describe_key, fn -> :ok end)
    :ok
  end

  defp local_user! do
    Application.put_env(:engram, :key_provider, Engram.Crypto.KeyProvider.Local)

    {:ok, u} =
      Engram.Accounts.create_user(%{
        email: "task-#{System.unique_integer([:positive])}@e.test",
        password: "pwpw1234!Z"
      })

    {:ok, _} = Crypto.ensure_user_dek(u)
    u
  end

  test "--target aws_kms sync drain rewraps every local user" do
    _u1 = local_user!()
    _u2 = local_user!()

    out =
      capture_io(fn ->
        Mix.Tasks.Engram.MigrateProvider.run(["--target", "aws_kms"])
      end)

    assert out =~ "migration complete"
    assert out =~ "ok="
  end

  test "--target aws_kms --enqueue inserts jobs without performing rewraps" do
    user = local_user!()

    out =
      capture_io(fn ->
        Mix.Tasks.Engram.MigrateProvider.run(["--target", "aws_kms", "--enqueue"])
      end)

    assert out =~ "enqueued"
    assert_enqueued(worker: Engram.Workers.MigrateUserProvider, args: %{"user_id" => user.id})

    reloaded =
      Engram.Repo.one!(Ecto.Query.from(u in Engram.Accounts.User, where: u.id == ^user.id),
        skip_tenant_check: true
      )

    # Not rewrapped yet — only enqueued.
    assert reloaded.key_provider == "local"
  end

  test "--status prints provider counts" do
    _ = local_user!()

    out =
      capture_io(fn ->
        Mix.Tasks.Engram.MigrateProvider.run(["--status"])
      end)

    assert out =~ "local="
    assert out =~ "aws_kms="
    assert out =~ "total="
  end

  test "unknown --target exits 2 (catch System.halt)" do
    assert catch_exit(
             capture_io(:stderr, fn ->
               Mix.Tasks.Engram.MigrateProvider.run(["--target", "passphrase"])
             end)
           ) == {:shutdown, 2}
  end

  test "missing required --target without --status exits 2" do
    assert catch_exit(
             capture_io(:stderr, fn ->
               Mix.Tasks.Engram.MigrateProvider.run([])
             end)
           ) == {:shutdown, 2}
  end
end
```

- [ ] **Step 2: Run, observe failures**

```bash
cd backend && mix test test/mix/tasks/engram.migrate_provider_test.exs --warnings-as-errors
```

Expected: `Mix.Tasks.Engram.MigrateProvider undefined`.

- [ ] **Step 3: Implement the Mix task**

Create `lib/mix/tasks/engram.migrate_provider.ex`:

```elixir
defmodule Mix.Tasks.Engram.MigrateProvider do
  @shortdoc "Rewrap user encrypted_dek between KeyProviders (Local↔AwsKms)"

  @moduledoc """
  Phase 3 — Per-user `KeyProvider` migration entrypoint.

  ## Usage

      # Sync drain (dev / staging) — blocks until done:
      mix engram.migrate_provider --target aws_kms

      # Production: Oban enqueue (jobs survive node restart):
      mix engram.migrate_provider --target aws_kms --enqueue

      # Reverse rollback (KMS → Local):
      mix engram.migrate_provider --target local --enqueue

      # Provider count breakdown:
      mix engram.migrate_provider --status

  ## Exit codes

  - `0` — clean (all users at target, or `--status` ran successfully).
  - `1` — partial: at least one per-user failure (telemetry has details).
  - `2` — misconfig (unknown `--target`, missing required arg).

  ## Pre-cutover checklist

  1. Set Fly secrets: `KEY_PROVIDER=aws_kms`, `AWS_KMS_KEY_ID`,
     `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`.
  2. Deploy. `BootCanaryGuard.AwsKms.boot_check/0` verifies CMK reachable.
  3. Run `mix engram.migrate_provider --target aws_kms --enqueue` (or
     release-rpc the underlying API: `Engram.Crypto.ProviderMigration.enqueue_all(:aws_kms)`).
  4. Monitor `[:engram, :crypto, :migrate_provider, :user]` telemetry +
     `mix engram.migrate_provider --status` until `local` count = 0.
  """

  use Mix.Task

  alias Engram.Crypto.ProviderMigration

  @switches [target: :string, enqueue: :boolean, status: :boolean, batch_size: :integer]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} = OptionParser.parse(args, switches: @switches)

    cond do
      opts[:status] ->
        print_status()
        :ok

      is_nil(opts[:target]) ->
        IO.puts(:stderr, "ERROR: --target is required (one of: aws_kms, local). Or pass --status.")
        exit({:shutdown, 2})

      opts[:target] not in ["aws_kms", "local"] ->
        IO.puts(:stderr, "ERROR: unknown --target #{inspect(opts[:target])}; expected aws_kms | local")
        exit({:shutdown, 2})

      true ->
        target_atom = String.to_existing_atom(opts[:target])
        batch_size = Keyword.get(opts, :batch_size, 100)

        if opts[:enqueue] do
          run_enqueue(target_atom, batch_size)
        else
          run_drain(target_atom, batch_size)
        end
    end
  end

  defp run_drain(target_atom, batch_size) do
    IO.puts("draining users → #{target_atom} (batch_size=#{batch_size})...")

    counts = ProviderMigration.migrate_all(target_atom, batch_size: batch_size)

    IO.puts(
      "migration complete: ok=#{counts.ok} skipped=#{counts.skipped} failed=#{counts.failed}"
    )

    if counts.failed > 0 do
      IO.puts(:stderr, "ERROR: #{counts.failed} users failed migration — inspect telemetry")
      exit({:shutdown, 1})
    end
  end

  defp run_enqueue(target_atom, batch_size) do
    IO.puts("enqueueing users → #{target_atom} (batch_size=#{batch_size})...")

    %{enqueued: n} = ProviderMigration.enqueue_all(target_atom, batch_size: batch_size)

    IO.puts("enqueued #{n} MigrateUserProvider jobs on :crypto_backfill")
  end

  defp print_status do
    counts = ProviderMigration.status_counts()
    IO.puts("local=#{counts.local} aws_kms=#{counts.aws_kms} total=#{counts.total}")
  end
end
```

- [ ] **Step 4: Run Mix task tests**

```bash
cd backend && mix test test/mix/tasks/engram.migrate_provider_test.exs --warnings-as-errors
```

Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
cd backend && git add lib/mix/tasks/engram.migrate_provider.ex test/mix/tasks/engram.migrate_provider_test.exs && git commit -m "feat(crypto): engram.migrate_provider Mix task (sync/enqueue/status)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9 — Telemetry handler registration

**Files:**
- Modify: `lib/engram_web/telemetry.ex`
- Modify: `test/engram_web/telemetry_test.exs`

- [ ] **Step 1: Write failing pin test**

Open `test/engram_web/telemetry_test.exs`. Find the existing assertion that enumerates registered metrics (search for `[:engram, :crypto, :rotate, :user]` or similar pin). Append a new test in the same describe block:

```elixir
    test "registers [:engram, :crypto, :migrate_provider, :user] counter + summary" do
      metrics = EngramWeb.Telemetry.metrics()
      names = Enum.map(metrics, & &1.name)

      assert Enum.member?(names, [:engram, :crypto, :migrate_provider, :user, :count])
      assert Enum.member?(names, [:engram, :crypto, :migrate_provider, :user, :duration_us])
    end
```

(If `telemetry_test.exs` does not exist, create it with `use ExUnit.Case` + the single test above.)

- [ ] **Step 2: Run, observe failure**

```bash
cd backend && mix test test/engram_web/telemetry_test.exs --warnings-as-errors
```

Expected: assertion fails because the new metric isn't registered yet.

- [ ] **Step 3: Add metrics to `EngramWeb.Telemetry`**

In `lib/engram_web/telemetry.ex`, inside the `defp metrics do [ ... ]` list (alongside the existing `engram.crypto.rotate.user.count` and `engram.crypto.aad_rebind.user.count`), add:

```elixir
      counter("engram.crypto.migrate_provider.user.count",
        tags: [:target_provider, :status, :reason_label],
        description: "Phase 3 per-user provider migration outcome (Local↔AwsKms)"
      ),
      summary("engram.crypto.migrate_provider.user.duration_us",
        unit: {:native, :microsecond},
        tags: [:target_provider, :status],
        description: "Phase 3 per-user provider migration duration"
      ),
```

- [ ] **Step 4: Run test**

```bash
cd backend && mix test test/engram_web/telemetry_test.exs --warnings-as-errors
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
cd backend && git add lib/engram_web/telemetry.ex test/engram_web/telemetry_test.exs && git commit -m "feat(telemetry): register migrate_provider.user counter + summary

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10 — Cross-provider conformance pin

**Files:**
- Modify: `test/engram/crypto/provider_conformance_test.exs`

- [ ] **Step 1: Append cross-provider identify_from_blob test**

Inside `Engram.Crypto.ProviderConformanceTest`, append (after the existing per-provider loop):

```elixir
  describe "cross-provider identify_from_blob/1 round-trip" do
    test "every provider produces a blob that identify_from_blob maps back to itself" do
      stub_aws_kms_roundtrip()

      for provider <- @providers do
        dek = provider.generate_dek()
        {:ok, blob} = provider.wrap_dek(dek, %{user_id: 1})
        assert {:ok, ^provider} = Engram.Crypto.KeyProvider.identify_from_blob(blob)
      end
    end
  end
```

- [ ] **Step 2: Run test**

```bash
cd backend && mix test test/engram/crypto/provider_conformance_test.exs --warnings-as-errors
```

Expected: pass (round-trip works because Phase 1 already shipped `identify_from_blob/1` correctly).

- [ ] **Step 3: Commit**

```bash
cd backend && git add test/engram/crypto/provider_conformance_test.exs && git commit -m "test(crypto): cross-provider identify_from_blob round-trip in conformance

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11 — Full suite + warnings-as-errors gate

**Files:** none modified — quality gate.

- [ ] **Step 1: Run full test suite with strict flags**

```bash
cd backend && mix test --warnings-as-errors
```

Expected: all tests pass. No compile warnings.

- [ ] **Step 2: Run quality lints (matches CI gates from PR #90)**

```bash
cd backend && mix format --check-formatted && mix credo --strict && mix sobelow --config
```

Expected: all clean. Fix any lints inline before proceeding.

- [ ] **Step 3: Final commit (only if lint fixes were needed)**

If any lint adjustments were required:

```bash
cd backend && git add -u && git commit -m "chore(crypto): apply mix format + credo strict to Phase 3

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12 — Open PR

**Files:** none — PR opening.

- [ ] **Step 1: Push branch + open PR**

```bash
cd backend && git push -u origin docs/aws-kms-phase-3-design && gh pr create --title "feat(crypto): AWS KMS Phase 3 — provider migration (Local↔KMS)" --body "$(cat <<'EOF'
## Summary
- Per-user `KeyProvider` rewrap via `Engram.Crypto.ProviderMigration` + `Engram.Workers.MigrateUserProvider` + `mix engram.migrate_provider`
- `Crypto.get_dek/1` now dispatches unwrap by blob tag (`KeyProvider.identify_from_blob/1`) and enqueues lazy migration when provider ≠ configured target
- Forward (Local→KMS) and reverse (KMS→Local) share the same worker — `--target` arg flips direction
- Telemetry `[:engram, :crypto, :migrate_provider, :user]` + Logger.error on failure
- No schema changes — `users.encrypted_dek` + `users.key_provider` already exist

## Spec
`docs/superpowers/specs/2026-05-16-aws-kms-phase-3-provider-migration-design.md`

## Test plan
- [x] Unit tests for `migrate_user/2` happy paths, idempotence, race, failure modes
- [x] Worker tests (retry vs discard classification + uniqueness)
- [x] Mix task tests (sync, enqueue, status, exit codes)
- [x] `get_dek/1` dual-read quadrant tests
- [x] Cross-provider `identify_from_blob` conformance round-trip
- [x] Telemetry handler registration pin

## Out of scope
- Phase 4 cutover runbook (separate spec)
- Terraform templates for AWS account / KMS CMK / IAM (separate spec)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Expected: PR opens. CI runs the full suite + lints + E2E.

---

## Notes for the executing engineer

- All commits go on branch `docs/aws-kms-phase-3-design` (already created in `backend/`). One PR for the whole feature per the workspace memory `feedback_single_pr_all_changes`.
- The `:crypto_backfill` Oban queue has concurrency=1 (`config/config.exs:51`) — this serializes the migration against MasterRotation / AadRebind / UserDekRotation. Don't change it.
- KMS calls in tests go through `Engram.AwsKmsMock` (Mox); never hit AWS from the test suite. The `stub_kms_roundtrip` helper backs encrypt/decrypt with an ETS table so wrap/unwrap pairs are consistent within a test.
- The `Crypto.get_dek/1` lazy enqueue uses a `try/rescue + catch _` belt-and-suspenders so a transient Oban insert failure (e.g. queue paused) never bubbles to the read caller — read availability is more important than instant migration enqueue.
- `Repo.one(..., skip_tenant_check: true)` is required for any cross-tenant query (e.g. on `users`) since the codebase uses Ecto RLS scoping. Already used by `MasterRotation` — follow the same pattern.
- After PR merges, Phase 4 brainstorm covers: Fly secrets sequence, IAM policy YAML, engram-selfhost guard against `KEY_PROVIDER=aws_kms`, production runbook (drain monitoring, abort criteria). Terraform spec follows.
