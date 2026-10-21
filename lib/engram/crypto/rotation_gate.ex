defmodule Engram.Crypto.RotationGate do
  @moduledoc """
  T3.7 — gate for per-user operations that must NOT run while a DEK
  rotation holds the user's lock.

  The `RotationLockCheck` plug already gates REST routes. This helper
  is for the other write paths — Phoenix channels and Oban workers —
  that don't pass through the plug pipeline.

  ## Usage

      case Engram.Crypto.RotationGate.check(user_id) do
        :ok -> proceed_with_write(...)
        {:error, :rotation_in_progress} -> back_off(...)
      end

  Or, when you have the user struct already loaded (e.g., from
  `socket.assigns.current_user`), pass it directly to skip the DB
  round-trip:

      Engram.Crypto.RotationGate.check_user(%User{} = user)

  Caveat: a user struct loaded BEFORE rotation begins will say
  `dek_rotation_locked_at: nil`. For correctness in long-lived
  contexts (open WebSocket sockets, Oban jobs that may have been
  enqueued seconds before lock acquire), prefer `check/1` which
  re-reads the user row.
  """

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts.User
  alias Engram.Repo

  @spec check(Ecto.UUID.t()) :: :ok | {:error, :rotation_in_progress | :user_not_found}
  def check(user_id) when is_binary(user_id) do
    # Select `{id, locked_at}` so we can distinguish "user not found" (nil)
    # from "user found, lock nil" ({id, nil}).
    case Repo.one(
           from(u in User,
             where: u.id == ^user_id,
             select: {u.id, u.dek_rotation_locked_at}
           ),
           skip_tenant_check: true
         ) do
      nil -> {:error, :user_not_found}
      {_id, %DateTime{}} -> {:error, :rotation_in_progress}
      {_id, _} -> :ok
    end
  end

  @doc """
  Run `fun` with every top-level `Repo.with_tenant/2` it opens refusing a
  user whose DEK rotation is locked: the transaction's own `tenant_enter`
  reads the lock (no extra round trip) and raises
  `Engram.Crypto.RotationInProgressError` before the block runs, so nothing is
  written. Called inside a tenant transaction (whose re-entrant blocks run
  no tenant_enter) it reads the lock once up front instead.
  """
  @spec gated((-> result)) :: result when result: term()
  def gated(fun) when is_function(fun, 0) do
    tenant = Process.get(:engram_tenant)

    if tenant && Repo.in_transaction?() && check(tenant) == {:error, :rotation_in_progress},
      do: raise(Engram.Crypto.RotationInProgressError)

    previous = Process.put(:engram_write_gate, true)

    try do
      fun.()
    after
      unless previous, do: Process.delete(:engram_write_gate)
    end
  end

  @spec check_user(User.t()) :: :ok | {:error, :rotation_in_progress}
  def check_user(%User{dek_rotation_locked_at: %DateTime{}}), do: {:error, :rotation_in_progress}
  def check_user(%User{}), do: :ok
end
