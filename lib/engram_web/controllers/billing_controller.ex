defmodule EngramWeb.BillingController do
  use EngramWeb, :controller

  alias Engram.Attachments
  alias Engram.Billing
  alias Engram.Billing.Subscriptions
  alias Engram.Connections
  alias Engram.Usage.DailyCap
  alias Engram.UsageMeters
  alias Engram.Vaults

  require Logger

  def status(conn, _params) do
    json(conn, status_payload(conn.assigns.current_user))
  end

  @doc """
  `GET /api/billing/usage` — the accumulating usage limits paired with their
  CURRENT values.

  The caps were always fetchable (`/billing/status`, `Billing.capabilities/1`)
  but nothing published the other half, so "how close am I?" was unanswerable
  from any client: the first time a user learned their number was the 402 that
  refused them. There is no per-user usage counter in Prometheus or Loki
  either — this endpoint is the answer to that gap, not a convenience.

  Scope is deliberately the limits that ACCUMULATE. Per-request ceilings
  (`max_file_bytes`) and connection caps (`obsidian_connections_cap`,
  `mcp_connections_cap` — already served by `/billing/status`) have no "used"
  to report and are not here.

  Most entries are `{used, limit}` with `limit: null` meaning uncapped,
  matching the `cap_json/1` convention the rest of this controller uses.

  The two daily search caps are `{remaining, limit}` instead, because a token
  bucket genuinely cannot answer "how many did you run today": it refills
  continuously, so a derived `used` DECAYS over the day (10 searches at 09:00
  reads as 0 by 13:00) and misreports outright after a cap change (raise the
  cap to 100 while the row still holds 15 tokens and `limit - remaining` claims
  85 used). `remaining` is the number the bucket actually holds and the number
  the user needs.

  Advisory only. `Billing.check_limit/3` and the plugs remain the authority —
  a client must not gate on this, and a stale read here can never grant
  anything.
  """
  def usage(conn, _params) do
    user = conn.assigns.current_user
    meters = UsageMeters.snapshot(user.id)

    json(conn, %{
      tier: to_string(Billing.tier(user)),
      usage: %{
        notes: used_limit(meters.notes, Billing.effective_limit(user, :notes_cap)),
        vaults: used_limit(Vaults.count_for(user), Billing.effective_limit(user, :vaults_cap)),
        attachment_bytes:
          used_limit(
            storage_used_bytes(user),
            Billing.effective_limit(user, :attachment_bytes_cap)
          ),
        lifetime_embed_tokens:
          used_limit(
            meters.lifetime_embed_tokens,
            Billing.effective_limit(user, :lifetime_embed_token_cap)
          ),
        ai_conversations_today:
          capped_used_limit(
            meters.ai_conversations_today,
            Billing.effective_limit(user, :ai_conversations_per_day)
          ),
        ai_queries_today:
          used_limit(meters.ai_queries_today, Billing.effective_limit(user, :ai_queries_per_day)),
        indexed_notes:
          used_limit(
            min(meters.notes, indexed_cap(user)),
            Billing.effective_limit(user, :indexed_notes_cap)
          ),
        external_ai_searches:
          bucket_remaining(
            user,
            "ext_search",
            Billing.effective_limit(user, :external_ai_searches_per_day)
          ),
        inapp_searches:
          bucket_remaining(
            user,
            "inapp_search",
            Billing.effective_limit(user, :inapp_searches_per_day)
          )
      }
    })
  end

  defp used_limit(used, limit), do: %{used: used, limit: cap_json(limit)}

  # `ConversationMeter.maybe_rotate_conversation/3` commits
  # `conversations_today + 1` BEFORE `day_cap_exceeded?/2` tests it, and the
  # rate-limited branch returns a plain tuple rather than `Repo.rollback`, so a
  # capped Free user persists 6 against a limit of 5. That is correct for the
  # meter (the check is `today > cap`) and wrong for a progress bar, which
  # would render 120%. Clamp for display only — the stored counter is
  # untouched and the gate remains the authority.
  defp capped_used_limit(used, limit) when is_integer(limit) and limit >= 0,
    do: %{used: min(used, limit), limit: limit}

  defp capped_used_limit(used, limit), do: used_limit(used, limit)

  # `indexed_notes_cap` binds FIRST on Free (2,000 against a 10,000
  # `notes_cap`), and it fails silently: the notes sync fine, they just stop
  # being searchable. A user reading only `notes: {used: 3000, limit: 10000}`
  # concludes they are fine while a third of their vault is invisible to
  # search — exactly the "you only learn the number when something refuses
  # you" gap this endpoint exists to close.
  defp indexed_cap(user) do
    case Billing.effective_limit(user, :indexed_notes_cap) do
      n when is_integer(n) and n >= 0 -> n
      _ -> :infinity
    end
  end

  # The search caps are token buckets, which track what is LEFT rather than
  # what was spent, and they refill continuously. Derive `used` so every entry
  # in the payload has the same shape; it is a floor because tokens are
  # fractional mid-refill and a user seeing "15 of 15 used" while one more
  # search still succeeds is worse than the reverse.
  # Floor rather than round: tokens are fractional mid-refill, and telling a
  # user they have 1 search left when the next call refuses them is worse than
  # the reverse.
  defp bucket_remaining(user, kind, limit) when is_integer(limit) and limit > 0 do
    %{remaining: trunc(DailyCap.remaining(user.id, kind, limit, limit / 86_400)), limit: limit}
  end

  # Cap of 0 means no budget at all; anything else (`nil`, `:unlimited`) means
  # no ceiling, so there is nothing to run out of.
  defp bucket_remaining(_user, _kind, 0), do: %{remaining: 0, limit: 0}
  defp bucket_remaining(_user, _kind, limit), do: %{remaining: nil, limit: cap_json(limit)}

  # Strict match, deliberately. `storage_usage/1` only fails on a DB error, and
  # reporting `used: 0` there would tell the user they have their whole quota
  # free — an over-optimistic fabrication on the one axis where being wrong
  # costs them an upload. A 500 is honest. Same shape as
  # `Attachments.validate_storage_cap/3`, which matches strictly for the same
  # reason.
  defp storage_used_bytes(user) do
    {:ok, %{used_bytes: n}} = Attachments.storage_usage(user)
    n
  end

  @doc """
  Builds the `GET /api/billing/status` JSON map for a user. Public so the
  consolidated `GET /api/bootstrap` endpoint serves the identical shape. Holds
  the *volatile* slice (live trial countdown, connection counts, swap cooldown)
  — the stable capability matrix is served separately via `Billing.capabilities/1`.
  """
  def status_payload(user) do
    sub = Billing.get_subscription(user)

    %{
      tier: to_string(Billing.tier(user)),
      active: Billing.tier(user) in [:starter, :pro],
      trial_days_remaining: Billing.trial_days_remaining(user),
      subscription:
        if sub do
          %{
            status: sub.status,
            tier: sub.tier,
            current_period_end: sub.current_period_end
          }
        end,
      caps: %{
        obsidian_connections: cap_json(Billing.effective_limit(user, :obsidian_connections_cap)),
        mcp_connections: cap_json(Billing.effective_limit(user, :mcp_connections_cap)),
        api_write_enabled: bool_json(Billing.effective_limit(user, :api_write_enabled)),
        vaults: cap_json(Billing.effective_limit(user, :vaults_cap))
      },
      # Bundled into /billing/status so the proactive cap UI on /link and
      # /oauth/consent only needs ONE fetch to decide whether to render the
      # disconnect panel vs the normal flow.
      current_connections: %{
        obsidian: Connections.count_active(user.id, :obsidian),
        mcp: Connections.count_active(user.id, :mcp)
      },
      # Free-tier swap cooldown: hours remaining until the user is allowed
      # to revoke + add another obsidian device family. `nil` when no
      # cooldown is in effect (no recent revoke, cooldown disabled, or
      # window already elapsed). Lets /link render a cooldown-specific
      # banner + disable Authorize BEFORE the user trips the 402.
      device_swap_cooldown_remaining_hours: swap_cooldown_remaining(user)
    }
  end

  # Mirrors `EnforceDeviceCap.remaining_cooldown_hours/2`: computed from
  # the most recent obsidian device revoke + the user's effective
  # `device_swap_cooldown_hours`. Returns the hour count (rounded UP) when
  # the user is still inside the window, else `nil`.
  defp swap_cooldown_remaining(user) do
    cooldown_hours = Billing.effective_limit(user, :device_swap_cooldown_hours)

    case Connections.most_recent_device_revoke(user.id) do
      %DateTime{} = revoked_at when is_integer(cooldown_hours) and cooldown_hours > 0 ->
        elapsed_seconds = DateTime.diff(DateTime.utc_now(), revoked_at, :second)
        window_seconds = cooldown_hours * 3600

        if elapsed_seconds < window_seconds do
          # Round up so a sub-hour remainder still surfaces as ≥ 1.
          div(window_seconds - elapsed_seconds + 3599, 3600)
        end

      _ ->
        nil
    end
  end

  @doc """
  Returns the public configuration the frontend needs to open the Paddle.js
  overlay. The client merges its own affiliate / utm params into
  `custom_data` before calling `Paddle.Checkout.open()`.
  """
  def config(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      client_token: Application.get_env(:engram, :paddle_client_token),
      environment: Application.get_env(:engram, :paddle_env, "sandbox"),
      price_ids: %{
        starter: %{
          monthly: Application.get_env(:engram, :paddle_starter_monthly_price_id),
          annual: Application.get_env(:engram, :paddle_starter_annual_price_id)
        },
        pro: %{
          monthly: Application.get_env(:engram, :paddle_pro_monthly_price_id),
          annual: Application.get_env(:engram, :paddle_pro_annual_price_id)
        }
      },
      customer_email: user.email,
      custom_data: %{user_id: user.id},
      vaults_cap: cap_json(Billing.effective_limit(user, :vaults_cap))
    })
  end

  # Normalizes an effective limit to a JSON-friendly value: a positive integer
  # cap, or `null` for "unlimited" (`:unlimited` / `nil` / `-1`). The frontend
  # treats `null` as no cap.
  defp cap_json(:unlimited), do: nil
  defp cap_json(nil), do: nil
  defp cap_json(-1), do: nil
  defp cap_json(limit) when is_integer(limit), do: limit
  # Unknown/malformed override (e.g. a non-integer value) → treat as no cap
  # rather than 500 the endpoint.
  defp cap_json(_), do: nil

  # Boolean LimitKey: :unlimited (limits disabled) opens the gate; explicit
  # true/false flows through; anything else collapses to false to fail-closed.
  defp bool_json(:unlimited), do: true
  defp bool_json(true), do: true
  defp bool_json(false), do: false
  defp bool_json(_), do: false

  @doc """
  Customer-portal redirect. Without an `action` param this returns the generic
  overview URL; with `action=cancel` / `action=update_payment` it returns the
  matching per-subscription deep link so the UI can offer distinct buttons.
  """
  def customer_portal(conn, params) do
    with_billing(conn, fn ->
      user = conn.assigns.current_user

      result =
        case params["action"] do
          nil -> Billing.create_portal_session(user)
          action -> Billing.portal_action_url(user, action)
        end

      respond_with_url(conn, result)
    end)
  end

  @doc "Live subscription detail (next bill, billing cycle, scheduled change)."
  def subscription_detail(conn, _params) do
    with_billing(conn, fn ->
      case Billing.subscription_detail(conn.assigns.current_user) do
        {:ok, detail} -> json(conn, detail)
        {:error, :no_subscription} -> not_found(conn, "no subscription")
        {:error, reason} -> paddle_error(conn, reason)
      end
    end)
  end

  @doc "Transaction history plus the card behind the latest card payment."
  def transactions(conn, _params) do
    with_billing(conn, fn ->
      case Billing.billing_history(conn.assigns.current_user) do
        {:ok, history} -> json(conn, history)
        {:error, :no_subscription} -> not_found(conn, "no subscription")
        {:error, reason} -> paddle_error(conn, reason)
      end
    end)
  end

  @doc "Mint the hosted invoice URL for one of the user's own transactions."
  def transaction_invoice(conn, %{"id" => transaction_id}) do
    with_billing(conn, fn ->
      case Billing.transaction_invoice_url(conn.assigns.current_user, transaction_id) do
        {:ok, url} -> json(conn, %{url: url})
        {:error, :no_subscription} -> not_found(conn, "no subscription")
        {:error, :not_found} -> not_found(conn, "transaction not found")
        {:error, reason} -> paddle_error(conn, reason)
      end
    end)
  end

  @doc """
  Cancel the user's subscription at the end of the current billing period.

  Maps the `Subscriptions.cancel/2` result to:
    * 202 — Paddle accepted, scheduled-change is in flight; webhook will
      mirror it back into our DB
    * 422 `no_active_subscription` — user has no Paddle subscription id
    * 422 `paddle_rejected` — Paddle returned 4xx (user-caused, e.g. sub
      already canceled or replaced). `paddle_status` in body.
    * 502 `paddle_upstream_error` — Paddle returned 5xx
    * 503 `paddle_unavailable` — transport failure (no HTTP response)
  """
  def cancel_subscription(conn, _params) do
    with_billing(conn, fn ->
      conn.assigns.current_user
      |> Subscriptions.cancel()
      |> respond_paddle(conn, ok_status: 202)
    end)
  end

  @doc "Reverse a scheduled cancel before its effective date."
  def reverse_cancel(conn, _params) do
    with_billing(conn, fn ->
      conn.assigns.current_user
      |> Subscriptions.reverse_cancel()
      |> respond_paddle(conn, ok_status: 202)
    end)
  end

  @doc """
  Preview the proration shape of a plan change. Read-only; safe to call as
  the user picks a target plan.
  """
  def plan_change_preview(conn, %{"target_price_id" => price_id}) when is_binary(price_id) do
    with_billing(conn, fn ->
      if valid_catalog_price_id?(price_id) do
        conn.assigns.current_user
        |> Subscriptions.preview_plan_change(price_id)
        |> respond_paddle(conn, ok_status: 200)
      else
        conn |> put_status(422) |> json(%{error: "invalid_price_id"})
      end
    end)
  end

  def plan_change_preview(conn, _params) do
    conn |> put_status(422) |> json(%{error: "target_price_id required"})
  end

  @doc "Commit a plan change after the user confirmed the inline preview."
  def plan_change_confirm(conn, %{"target_price_id" => price_id}) when is_binary(price_id) do
    with_billing(conn, fn ->
      if valid_catalog_price_id?(price_id) do
        conn.assigns.current_user
        |> Subscriptions.confirm_plan_change(price_id)
        |> respond_paddle(conn, ok_status: 202)
      else
        conn |> put_status(422) |> json(%{error: "invalid_price_id"})
      end
    end)
  end

  def plan_change_confirm(conn, _params) do
    conn |> put_status(422) |> json(%{error: "target_price_id required"})
  end

  # Single response mapper for the four user-initiated subscription actions.
  # Distinguishes Paddle 4xx (user-caused) from 5xx (upstream outage) from
  # transport failure (`:paddle_unavailable`) so log dashboards and support
  # can triage without re-parsing strings — and so the frontend can show a
  # 'try again' message for 5xx but a 'this won't work' message for 4xx.
  defp respond_paddle({:ok, data}, conn, opts) do
    conn |> put_status(Keyword.fetch!(opts, :ok_status)) |> json(data)
  end

  defp respond_paddle({:error, :no_active_subscription}, conn, _opts) do
    conn |> put_status(422) |> json(%{error: "no_active_subscription"})
  end

  defp respond_paddle({:error, {:paddle_error, status, body}}, conn, _opts)
       when status >= 400 and status < 500 do
    conn
    |> put_status(422)
    |> json(paddle_error_payload("paddle_rejected", status, body))
  end

  defp respond_paddle({:error, {:paddle_error, status, body}}, conn, _opts) do
    conn
    |> put_status(502)
    |> json(paddle_error_payload("paddle_upstream_error", status, body))
  end

  defp respond_paddle({:error, :paddle_unavailable}, conn, _opts) do
    conn |> put_status(503) |> json(%{error: "paddle_unavailable"})
  end

  # Paddle errors come back as `%{"error" => %{"code" => ..., "detail" => ...,
  # "documentation_url" => ...}}`. Surface the code + detail in our API
  # response so the user can see WHY Paddle rejected the request without
  # SSH-ing to the backend. Fall back to bare status if the body shape
  # doesn't match — older Paddle endpoints sometimes return plain text.
  defp paddle_error_payload(error, status, body) do
    base = %{error: error, paddle_status: status}

    case body do
      %{"error" => %{"code" => code} = err} when is_binary(code) ->
        base
        |> Map.put(:paddle_code, code)
        |> maybe_put(:paddle_detail, Map.get(err, "detail"))

      _ ->
        base
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp maybe_put(map, _key, _other), do: map

  # Allow-list: only the 4 catalog price IDs surfaced by /billing/config are
  # valid plan-change targets. Without this guard a caller could submit an
  # arbitrary Paddle price (sibling product, archived $0, deprecated tier) and
  # Paddle might accept the swap, letting users escape the catalog.
  defp valid_catalog_price_id?(price_id) do
    catalog =
      [
        Application.get_env(:engram, :paddle_starter_monthly_price_id),
        Application.get_env(:engram, :paddle_starter_annual_price_id),
        Application.get_env(:engram, :paddle_pro_monthly_price_id),
        Application.get_env(:engram, :paddle_pro_annual_price_id)
      ]
      |> Enum.filter(&is_binary/1)

    price_id in catalog
  end

  @doc "Mint a transaction id for the in-app Paddle.js payment-method overlay."
  def payment_update_transaction(conn, _params) do
    with_billing(conn, fn ->
      case Billing.update_payment_transaction(conn.assigns.current_user) do
        {:ok, transaction_id} -> json(conn, %{transaction_id: transaction_id})
        {:error, :no_subscription} -> not_found(conn, "no subscription")
        {:error, reason} -> paddle_error(conn, reason)
      end
    end)
  end

  # Self-host (billing_enabled=false) never reaches Paddle: the page is hidden
  # client-side, but gate here too so a direct request 404s instead of erroring.
  defp with_billing(conn, fun) do
    if Application.get_env(:engram, :billing_enabled, false) == true do
      fun.()
    else
      not_found(conn, "billing disabled")
    end
  end

  defp respond_with_url(conn, {:ok, url}), do: json(conn, %{url: url})
  defp respond_with_url(conn, {:error, :no_subscription}), do: not_found(conn, "no subscription")
  defp respond_with_url(conn, {:error, reason}), do: paddle_error(conn, reason)

  defp not_found(conn, message), do: conn |> put_status(404) |> json(%{error: message})

  defp paddle_error(conn, reason) do
    Logger.error(
      "Paddle billing error",
      Engram.Logger.Metadata.with_category(:error, :billing, reason_label: inspect(reason))
    )

    conn |> put_status(502) |> json(%{error: "payment provider error"})
  end
end
