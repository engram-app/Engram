defmodule Engram.Crypto.UserDekRotation do
  @moduledoc """
  T3.7 — per-user DEK rotation orchestrator. Generates a new DEK for the
  target user, rewraps every ciphertext column on every owned row
  (notes / vaults / attachments / Qdrant payloads) under the new key,
  then atomically flips `users.encrypted_dek`.

  The user is locked (read + write) for the duration via
  `Engram.Crypto.RotationLock`; clients receive HTTP 503 with
  `Retry-After: 60` until the rotation completes.

  See `docs/encryption-tier-3-audit.md` § Phase T3.7.
  """

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Crypto.{DekCache, RotationLock}
  alias Engram.Crypto.KeyProvider.Resolver
  alias Engram.Repo

  require Logger

  @type rotate_result :: :ok | :skipped | {:error, term()}

  @spec rotate_user(integer() | User.t(), pos_integer()) :: rotate_result()
  def rotate_user(user_or_id, target_dek_version)
      when is_integer(target_dek_version) and target_dek_version >= 1 do
    user_id =
      case user_or_id do
        %User{id: id} -> id
        id when is_integer(id) -> id
      end

    started_at = System.monotonic_time()
    result = do_rotate(user_id, target_dek_version)
    duration_us = duration_us_since(started_at)
    emit_telemetry(user_id, target_dek_version, result, duration_us)
    result
  end

  defp do_rotate(user_id, target_dek_version) do
    with {:ok, user} <- load_user(user_id),
         :continue <- short_circuit_if_at_target(user, target_dek_version),
         {:ok, _locked_at} <- RotationLock.acquire(user_id, target_dek_version: target_dek_version) do
      try do
        run_phases(user, target_dek_version)
      rescue
        e ->
          Logger.error(
            "T3.7 rotate_user crashed user_id=#{user_id} kind=#{inspect(e.__struct__)} message=#{Exception.message(e)}",
            category: :crypto_rotation
          )

          # Lock intentionally NOT released — operator must investigate
          # before retry. Re-raise so caller sees the failure.
          reraise e, __STACKTRACE__
      end
    else
      :skipped -> :skipped
      {:error, _} = err -> err
    end
  end

  defp load_user(user_id) do
    case Repo.one(from(u in User, where: u.id == ^user_id, select: u), skip_tenant_check: true) do
      nil -> {:error, :not_found}
      %User{} = u -> {:ok, u}
    end
  end

  defp short_circuit_if_at_target(%User{dek_version: v}, target) when v >= target, do: :skipped
  defp short_circuit_if_at_target(_user, _target), do: :continue

  defp run_phases(%User{} = user, target_dek_version) do
    user_id = user.id

    with {:ok, _old_dek} <- Crypto.get_dek(user),
         provider = Resolver.provider_for(user_id),
         {:ok, new_wrapped, _new_dek} <-
           provider.rotate_dek(user.encrypted_dek, %{user_id: user_id}),
         :ok <- final_flip(user, target_dek_version, new_wrapped) do
      :ok
    else
      {:error, _} = err -> err
    end
  end

  defp final_flip(%User{} = user, target_dek_version, new_wrapped) do
    Repo.transaction(fn ->
      {1, _} =
        from(u in User, where: u.id == ^user.id)
        |> Repo.update_all(
          [
            set: [
              encrypted_dek: new_wrapped,
              dek_version: target_dek_version,
              dek_rotation_locked_at: nil
            ]
          ],
          skip_tenant_check: true
        )

      DekCache.invalidate(user.id)
      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp duration_us_since(started_at) do
    System.convert_time_unit(
      System.monotonic_time() - started_at,
      :native,
      :microsecond
    )
  end

  defp emit_telemetry(user_id, target, :ok, duration_us) do
    :telemetry.execute(
      [:engram, :crypto, :rotate, :dek],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, target_dek_version: target, status: :ok}
    )
  end

  defp emit_telemetry(user_id, target, :skipped, duration_us) do
    :telemetry.execute(
      [:engram, :crypto, :rotate, :dek],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, target_dek_version: target, status: :skipped}
    )
  end

  defp emit_telemetry(user_id, target, {:error, reason}, duration_us) do
    label = classify_reason(reason)

    Logger.error(
      "T3.7 rotate_user failed user_id=#{user_id} target=#{target} reason_label=#{label}",
      category: :crypto_rotation
    )

    :telemetry.execute(
      [:engram, :crypto, :rotate, :dek],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, target_dek_version: target, status: :failed, reason_label: label}
    )
  end

  defp classify_reason(:not_found), do: "not_found"
  defp classify_reason(:rotation_in_progress), do: "rotation_in_progress"
  defp classify_reason(:invalid_wrapping), do: "invalid_wrapping"
  defp classify_reason(:malformed_wrapped_blob), do: "malformed_wrapped_blob"
  defp classify_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp classify_reason(%Ecto.Changeset{}), do: "changeset_invalid"

  defp classify_reason(reason) when is_exception(reason),
    do: reason.__struct__ |> Module.split() |> List.last()

  defp classify_reason(_other), do: "other"
end
