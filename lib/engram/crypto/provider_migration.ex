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
