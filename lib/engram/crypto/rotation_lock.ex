defmodule Engram.Crypto.RotationLock do
  @moduledoc """
  T3.7 — per-user rotation lock. Held on `users.dek_rotation_locked_at`
  with a Postgres advisory lock guarding the acquire-or-takeover
  transition.

  Lifecycle:

      acquire(user_id, target_dek_version: 2)  # sets locked_at = now()
      ... rotation work ...
      release(user_id)                          # clears locked_at

  Stale-lock takeover: if `locked_at` is older than `@stale_after_seconds`,
  a new `acquire/2` overwrites the timestamp (assumes prior attempt crashed).
  The advisory lock is auto-released on transaction commit/rollback because
  we use `pg_advisory_xact_lock`.

  Stale-takeover SAFETY: if the prior crashed run left any
  `attachments.dek_version_pending` non-null for this user, takeover is
  REFUSED with `{:error, :half_state_pending}`. The S3 blob for those
  attachments is encrypted under a DEK that is no longer reachable
  (held only in the dead BEAM's heap). A fresh rotation would generate a
  different DEK and corrupt those blobs irreversibly. Operator must
  restore from S3 versioning + clear `dek_version_pending` + clear
  `dek_rotation_locked_at` manually before retry. See runbook
  § T3.7.4 "Half-state recovery".
  """

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias Engram.Attachments.Attachment
  alias Engram.Repo

  @stale_after_seconds 10 * 60

  @spec acquire(integer(), keyword()) ::
          {:ok, DateTime.t()}
          | {:error, :rotation_in_progress | :not_found | :half_state_pending}
  def acquire(user_id, _opts \\ []) when is_integer(user_id) do
    Repo.transaction(fn ->
      # Postgres advisory lock keyed on the user — serializes concurrent
      # acquire/2 callers without holding a row-level lock that would
      # also block the rotation worker's per-batch FOR UPDATE on the same row.
      key = :erlang.phash2({user_id, :dek_rotation}, 2_147_483_647)
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [key])

      case Repo.one(from(u in User, where: u.id == ^user_id), skip_tenant_check: true) do
        nil ->
          Repo.rollback(:not_found)

        %User{dek_rotation_locked_at: nil} = u ->
          set_locked(u)

        %User{dek_rotation_locked_at: at} = u ->
          if stale?(at) do
            if half_state_pending?(user_id) do
              Repo.rollback(:half_state_pending)
            else
              set_locked(u)
            end
          else
            Repo.rollback(:rotation_in_progress)
          end
      end
    end)
  end

  @spec release(integer()) :: :ok
  def release(user_id) when is_integer(user_id) do
    case from(u in User, where: u.id == ^user_id)
         |> Repo.update_all([set: [dek_rotation_locked_at: nil]], skip_tenant_check: true) do
      {1, _} ->
        :ok

      {0, _} ->
        require Logger

        Logger.error(
          "T3.7 RotationLock.release: user row vanished",
          category: :crypto_rotation,
          user_id: user_id,
          table: :users,
          row_id: user_id,
          phase: :release
        )

        raise "T3.7 RotationLock.release: row vanished mid-rotation user_id=#{user_id}"
    end
  end

  @spec locked?(integer()) :: boolean()
  def locked?(user_id) when is_integer(user_id) do
    Repo.one(
      from(u in User, where: u.id == ^user_id, select: not is_nil(u.dek_rotation_locked_at)),
      skip_tenant_check: true
    ) || false
  end

  # ── private ─────────────────────────────────────────────────────────────

  defp set_locked(%User{} = user) do
    now = DateTime.truncate(DateTime.utc_now(), :microsecond)

    case from(u in User, where: u.id == ^user.id)
         |> Repo.update_all([set: [dek_rotation_locked_at: now]], skip_tenant_check: true) do
      {1, _} ->
        now

      {0, _} ->
        # User was deleted between the SELECT and the UPDATE inside the advisory lock.
        # Roll back so acquire/2 returns {:error, :not_found} to the caller.
        Repo.rollback(:not_found)
    end
  end

  defp stale?(%DateTime{} = at) do
    DateTime.diff(DateTime.utc_now(), at, :second) > @stale_after_seconds
  end

  defp half_state_pending?(user_id) do
    count =
      Repo.one(
        from(a in Attachment,
          where: a.user_id == ^user_id and not is_nil(a.dek_version_pending),
          select: count(a.id)
        ),
        skip_tenant_check: true
      )

    count > 0
  end
end
