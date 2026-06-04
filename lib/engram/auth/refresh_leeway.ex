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

  Keeping the policy in one module means widening or narrowing the window
  changes both code paths atomically.
  """

  @seconds 30

  @doc "Width of the leeway window in seconds."
  def seconds, do: @seconds

  @doc """
  Returns true when `revoked_at` is within the leeway window relative to
  `now` — i.e. a legitimate concurrent rotation race. Outside the window =
  reuse breach. Boundary inclusive (`revoked_at == now - leeway` is still
  benign) so 1-second rounding can't flip a benign retry into a breach.
  """
  def benign?(%DateTime{} = revoked_at, %DateTime{} = now) do
    cutoff =
      now
      |> DateTime.add(-@seconds, :second)
      |> DateTime.truncate(:second)

    DateTime.compare(revoked_at, cutoff) != :lt
  end
end
