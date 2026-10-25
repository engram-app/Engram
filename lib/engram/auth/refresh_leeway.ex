defmodule Engram.Auth.RefreshLeeway do
  @moduledoc """
  Shared rotation-leeway policy for refresh tokens.

  Both the local-auth refresh path (`Engram.Accounts.consume_refresh_token/1`)
  and the device-flow refresh path (`Engram.Auth.DeviceFlow.refresh_access_token/1`)
  follow RFC 9700 §4.14.2: rotating refresh tokens are single-use, BUT a brief
  reuse-acceptance window is allowed so legitimate concurrent rotations (a
  plugin reload mid-refresh, two SPA tabs racing on mount, a request and its
  retry sharing the same just-rotated cookie) don't get misclassified as
  reuse-breach.

  Auth0 calls this the "rotation overlap period" and recommends the shortest
  viable value. Plugin and browser races resolve in <1s; 30s gives ample
  cushion without leaving the breach detection meaningfully softer (a stolen
  token replayed minutes later is still caught).

  MCP OAuth (`Engram.OAuth`) uses 60s, but its grace re-issue revokes the live
  successor, refuses once a successor was used, and caps re-issues. Within
  this window both paths here mint a child with none of that, so a token
  stolen and rotated inside it forks the family undetected; a wider window
  widens that. Follow-up: port MCP's successor-unused check and re-issue cap
  into one shared rotation-grace module (#2211), then raise this to 60s with it.

  Keeping the policy in one module means widening or narrowing the window
  changes both code paths atomically.
  """

  @seconds 30

  @doc "Width of the leeway window in seconds."
  def seconds, do: @seconds

  @doc """
  The `revoked_at` an admin-side revoke stamps (logout-everywhere, password
  reset, account delete, a local-auth breach kill). Epoch 0: outside any
  leeway, and never read as a user's Disconnect by the device-swap cooldown
  (`Engram.Connections.most_recent_device_revoke/1`).
  """
  def admin_revoked_at, do: ~U[1970-01-01 00:00:00Z]

  @doc """
  Serializes, for one user, every refresh rotation with every revoke of that
  user's refresh tokens (#2231). Without it a refresh that read its token
  live before a Disconnect committed still mints a live child. A
  transaction-scoped advisory lock (`pg_advisory_xact_lock`), so it cannot
  leak on an error path: call it inside a transaction, before reading or
  writing any refresh-token row.
  """
  @spec lock_user!(Ecto.UUID.t()) :: :ok
  def lock_user!(user_id) do
    if not Engram.Repo.in_transaction?(),
      do: raise(ArgumentError, "lock_user!/1 needs a transaction")

    Engram.Repo.advisory_lock!("refresh_tokens:#{user_id}")
  end

  @doc """
  Returns true when a revoked refresh token may still rotate: it was revoked
  within the leeway window AND its family still has a live token.

  The family check is what separates a rotation from a revoke (#2231). A
  rotation always leaves a live successor in the family; Disconnect, vault
  delete, logout-everywhere, account delete and a breach kill revoke every
  live row. Without it, a token revoked "now" by a user, or its predecessor
  rotated seconds earlier, lands inside the window and mints a fresh live
  token, so the disconnected device comes back.

  Works on any refresh-token schema with `revoked_at` and `family_id`.
  """
  def benign?(%schema{revoked_at: %DateTime{} = revoked_at} = token, %DateTime{} = now) do
    within_window?(revoked_at, now) and family_live?(schema, token.family_id)
  end

  @doc "True when some token of the family is unrevoked."
  def family_live?(%schema{family_id: family_id}), do: family_live?(schema, family_id)

  defp family_live?(schema, family_id) do
    import Ecto.Query

    from(t in schema, where: t.family_id == ^family_id and is_nil(t.revoked_at))
    |> Engram.Repo.exists?(skip_tenant_check: true)
  end

  @doc """
  True when `revoked_at` is inside the leeway window relative to `now`.
  Boundary inclusive (`revoked_at == now - leeway` is still inside) so
  1-second rounding can't flip a benign retry into a breach.
  """
  def within_window?(%DateTime{} = revoked_at, %DateTime{} = now) do
    cutoff =
      now
      |> DateTime.add(-@seconds, :second)
      |> DateTime.truncate(:second)

    DateTime.compare(revoked_at, cutoff) != :lt
  end
end
