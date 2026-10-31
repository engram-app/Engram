defmodule EngramWeb.SyncRateLimit do
  @moduledoc """
  The per-device and per-account sync budgets the CRDT socket charges each
  frame, shared with the REST endpoints that do the same work (notes
  batch-delete), so a client cannot double its budget by switching transport.

  Two buckets, both must allow:

    1. per device, `<class>:<user_id>:<device>`. The `user_id` prefix is
       server-derived, so a client-supplied device id only refines within its
       own tenant: it can never collide with another user's bucket.
    2. per account, `<class>:acct:<user_id>` at `@account_multiplier` times the
       limit, so forging device ids or opening many sockets cannot multiply the
       budget without bound.

  Per device is checked first, so a device already over its own budget does
  not also spend from the account ceiling.
  """

  # 240 frames / 10 s is about 24 msg/s sustained: well above human typing with
  # a 2 s client debounce, low enough to stop scripted floods.
  @msg_limit 240
  @scale_ms 10_000

  # Handshake (STEP1/STEP2) budget, separate from @msg_limit so connect-time
  # enrollment (one STEP1 per note) can never starve edit frames (the
  # 2026-07-07 incident trigger on a ~230-note vault). 2400/10s enrolls a
  # 2400-note vault inside one window; bounded, not exempt.
  @hs_limit 2400

  # Account-wide ceiling = limit x this: "up to ten busy devices per account".
  @account_multiplier 10

  @type class :: :handshake | :edit

  @doc """
  Charges `increment` units of `class` to the device and account buckets.
  `device` is the client's device id, or nil (one shared bucket per user).
  """
  @spec check(Ecto.UUID.t(), String.t() | nil, class(), pos_integer()) ::
          :ok | {:error, :rate_limited}
  def check(user_id, device, class, increment \\ 1) do
    {prefix, limit} =
      case class do
        :handshake -> {"crdt_hs", hs_limit()}
        :edit -> {"crdt_msg", msg_limit()}
      end

    with {:allow, _} <- hit("#{prefix}:#{user_id}:#{device || "u"}", limit, increment),
         {:allow, _} <- hit("#{prefix}:acct:#{user_id}", limit * @account_multiplier, increment) do
      :ok
    else
      {:deny, _} -> {:error, :rate_limited}
    end
  end

  defp hit(key, limit, increment),
    do: EngramWeb.RateLimiter.hit(key, @scale_ms, limit, :other, increment)

  # Both limits are overridable via app env (a cached ETS read, so per-message
  # cheap). Two writers set it, never prod:
  #   - unit tests: Application.put_env(:engram, :crdt_msg_rate_limit_override, n)
  #     so a test need not push 241 frames.
  #   - CI/E2E release stacks: config/runtime.exs sets it from the CI-gated
  #     CRDT_*_RATE_LIMIT_OVERRIDE env (Engram.RuntimeConfig), because the
  #     harness's compressed workload legitimately exceeds the per-account budget.
  # Prod never sets either, so the constant applies there and the limiter stays
  # un-weakenable in production. `||`, not `get_env/3`'s default: a test
  # restoring an unset override leaves the key set to nil.
  defp msg_limit, do: Application.get_env(:engram, :crdt_msg_rate_limit_override) || @msg_limit
  defp hs_limit, do: Application.get_env(:engram, :crdt_hs_rate_limit_override) || @hs_limit
end
