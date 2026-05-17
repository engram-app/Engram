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

  The plaintext DEK is unchanged across rewrap (only its wrapping
  changes), so `DekCache` entries remain valid and do NOT need
  invalidation. The `:sensitive` process flag is set at entry to keep
  the DEK out of any crash dump if the wrap call raises.

  ## `dek_version` after migration

  `dek_version` tracks master-key generation, not provider. After
  rewrap, the new blob is encoded under the current master-key version
  (Local always; AwsKms ignores it but stamps the column so a
  subsequent `MasterRotation` pass correctly skips just-migrated rows).
  Stamping `dek_version: Config.master_key_version()` is the right
  floor for both providers.
  """

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Crypto.{Config, KeyProvider}
  alias Engram.Crypto.KeyProvider.{AwsKms, Local}
  alias Engram.Repo

  require Logger

  @type provider_atom :: :local | :aws_kms
  @type migrate_result :: :ok | :skipped | {:error, term()}
  @type counts :: %{ok: non_neg_integer(), skipped: non_neg_integer(), failed: non_neg_integer()}

  @doc "Migrate one user's wrapped DEK to `target_provider`."
  @spec migrate_user(integer() | User.t(), provider_atom()) :: migrate_result()
  def migrate_user(user_or_id, target_provider) when target_provider in [:local, :aws_kms] do
    Process.flag(:sensitive, true)

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
      {:migrated, _user} -> :ok
      {:skipped, _user} -> :skipped
      {:error, reason} -> {:error, reason}
    end
  end

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
    target_name = Atom.to_string(target_provider)

    already_at_target =
      from(u in User,
        where: not is_nil(u.encrypted_dek) and u.key_provider == ^target_name,
        select: count(u.id)
      )
      |> Repo.one(skip_tenant_check: true)

    drive_loop(target_provider, 0, batch_size, %{
      ok: 0,
      skipped: already_at_target || 0,
      failed: 0
    })
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
      {:ok, {:migrated, user}} -> {:migrated, user}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rewrap_locked(%User{} = locked, target_module, target_name) do
    with {:ok, source_module} <- KeyProvider.identify_from_blob(locked.encrypted_dek),
         ctx = %{
           user_id: locked.id,
           dek_version: locked.dek_version,
           master_key_version: Engram.Crypto.Config.master_key_version()
         },
         {:ok, dek} <- source_module.unwrap_dek(locked.encrypted_dek, ctx),
         {:ok, new_blob} <- target_module.wrap_dek(dek, ctx),
         {:ok, updated} <-
           Accounts.update_user_encryption(locked, %{
             encrypted_dek: new_blob,
             key_provider: target_name,
             dek_version: Config.master_key_version()
           }) do
      {:migrated, updated}
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

  defp emit_telemetry(user_id, target_provider, {:migrated, _}, duration_us) do
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

  defp classify_reason(reason) when is_exception(reason),
    do: reason.__struct__ |> Module.split() |> List.last()

  defp classify_reason(_other), do: "other"

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
end
