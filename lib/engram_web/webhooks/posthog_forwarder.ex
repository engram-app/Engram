defmodule EngramWeb.Webhooks.PostHogForwarder do
  @moduledoc """
  Maps verified inbound Clerk + Paddle webhook events to PostHog product
  events. Lives next to the controller (not in the contexts) because the
  mapping is an integration concern — what Clerk/Paddle call an event vs.
  what the funnel calls a step. The contexts shouldn't know about either
  vendor's payload shape.

  All forwarders run AFTER the underlying handler completes, so a PostHog
  failure can never roll back business state. `Engram.Analytics.track/3` is itself
  fire-and-forget (Task.start) — these helpers never block on network I/O
  and always return `:ok`.

  distinct_id MUST be the keyed analytics id (`Engram.Analytics` resolves it,
  hashed from the user's email) — not the raw Clerk id — or the funnel
  silently fails to join once the frontend identifies by the same id:

  - Clerk events carry only the Clerk user id in the payload (`data.id`
    for user.created, `data.user_id` for session.created — they're not
    the same key, Clerk's session row references the user it belongs
    to), so each handler loads the local user by external_id and hashes
    its email.
  - Paddle events carry an *internal* `custom_data.user_id`; we resolve
    through the Subscription row to the user, then hash its email.
  """

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Analytics.PersonProperties
  alias Engram.Billing.Subscription
  alias Engram.Feedback
  alias Engram.Webhooks.Idempotency

  @doc """
  Forward a verified Clerk webhook event. Returns `:ok` for every input
  shape — unhandled event types are a no-op so adding a new Clerk webhook
  destination doesn't accidentally break this handler.
  """
  @spec forward_clerk_event(map()) :: :ok
  def forward_clerk_event(%{"type" => "user.created", "data" => %{"id" => clerk_id}})
      when is_binary(clerk_id) do
    capture_by_clerk_id(clerk_id, "user_signed_up")
    :ok
  end

  def forward_clerk_event(%{"type" => "session.created", "data" => %{"user_id" => clerk_id}})
      when is_binary(clerk_id) do
    capture_by_clerk_id(clerk_id, "user_signed_in")
    :ok
  end

  def forward_clerk_event(_event), do: :ok

  # Clerk webhooks carry only the Clerk id. Resolve it to the local user's
  # email so the event is keyed by the analytics id instead. If the local
  # row doesn't exist yet (e.g. a duplicate-signup revoked before this
  # handler runs), drop silently — there's no analytics identity to join on.
  defp capture_by_clerk_id(clerk_id, event) do
    case Accounts.find_by_external_id(clerk_id) do
      {:ok, %{email: email} = user} when is_binary(email) and byte_size(email) > 0 ->
        _ = Engram.Analytics.track(user, event, %{})
        :ok

      _ ->
        :ok
    end
  end

  @intervals ~w(day week month year)
  @origins ~w(web api subscription_recurring subscription_charge subscription_update subscription_payment_method_change)
  @currencies ~w(USD EUR GBP JPY AUD CAD CHF HKD SGD SEK ARS BRL CLP CNY COP CZK DKK HUF ILS INR KRW MXN NOK NZD PEN PLN RUB THB TRY TWD UAH VND ZAR)
  # Paddle amounts are strings in the lowest unit; these have no minor unit.
  @zero_decimal ~w(JPY KRW CLP)
  @tier_rank %{"free" => 0, "starter" => 1, "pro" => 2}
  @lapsed ~w(past_due paused canceled)

  @doc """
  Forward a verified Paddle webhook event paired with the result of
  `Engram.Billing.upsert_from_paddle_event/1`, as the billing lifecycle:

    * `subscription.created` while trialing: `subscription_trial_started`
    * `subscription.activated`: `subscription_started`
    * `subscription.updated`: `subscription_changed{kind}` when the tier moved
      (`upgrade`/`downgrade`), a cancel was scheduled (`cancel_scheduled`), or
      a lapsed status returned to active (`reactivated`). A renewal or any
      other state-sync update sends nothing.
    * `subscription.canceled`, `subscription.past_due`: same names. A cancel
      with no reason on file since the subscription started also files
      `subscription_cancel_reason` as `portal_no_reason` (or `payment_failed`
      out of `past_due`), so cancels made in Paddle's portal stay countable
    * `transaction.completed`: `payment_completed` with bucketed amount
    * `adjustment.*` approved refund or chargeback: `refund_issued`, once
      per adjustment id

  Every prop is a bounded enum, bucket or Paddle id. `interval` and
  `discounted` separate comped (100%-off) subs from real payers.
  """
  @spec forward_paddle_event(map(), struct() | term()) :: :ok
  def forward_paddle_event(
        %{"event_type" => "subscription.activated", "data" => data},
        %Subscription{} = sub
      ) do
    price_id = data |> Map.get("items", []) |> List.first(%{}) |> get_in(["price", "id"])

    track_sub(
      sub,
      "subscription_started",
      Map.merge(cycle_props(data), %{
        tier: sub.tier,
        price_id: price_id,
        paddle_subscription_id: sub.paddle_subscription_id
      })
    )
  end

  def forward_paddle_event(
        %{"event_type" => "subscription.created", "data" => %{"status" => "trialing"} = data},
        %Subscription{} = sub
      ) do
    track_sub(sub, "subscription_trial_started", Map.put(cycle_props(data), :tier, sub.tier))
  end

  def forward_paddle_event(
        %{"event_type" => "subscription.updated", "data" => data},
        %Subscription{previous: %{tier: from, status: prev_status}} = sub
      ) do
    case change_kind(from, prev_status, sub, data) do
      nil ->
        :ok

      kind ->
        track_sub(sub, "subscription_changed", %{
          kind: kind,
          from_tier: from,
          to_tier: sub.tier,
          status: sub.status
        })
    end
  end

  def forward_paddle_event(
        %{"event_type" => "subscription.canceled", "data" => data},
        %Subscription{} = sub
      ) do
    from = if sub.previous, do: sub.previous.tier, else: sub.tier
    :ok = track_sub(sub, "subscription_canceled", %{from_tier: from, status: sub.status})

    # A dunning failure is involuntary churn, not a portal cancel.
    reason =
      if sub.previous && sub.previous.status == "past_due",
        do: "payment_failed",
        else: "portal_no_reason"

    with %User{} = user <- Accounts.get_user(sub.user_id) do
      Feedback.record_missing_cancel_reason(user, started_at(data, sub), reason)
    end

    :ok
  end

  def forward_paddle_event(%{"event_type" => "subscription.past_due"}, %Subscription{} = sub) do
    track_sub(sub, "subscription_past_due", %{tier: sub.tier, status: sub.status})
  end

  # Paddle copies the checkout's custom_data (our user_id) onto the
  # subscription and every renewal transaction it creates.
  def forward_paddle_event(%{"event_type" => "transaction.completed", "data" => data}, _result) do
    with {:ok, user_id} <- Ecto.UUID.cast(get_in(data, ["custom_data", "user_id"])),
         %{email: email} = user when is_binary(email) and byte_size(email) > 0 <-
           Accounts.get_user(user_id) do
      interval =
        data
        |> Map.get("items", [])
        |> List.first(%{})
        |> get_in(["price", "billing_cycle", "interval"])

      _ =
        Engram.Analytics.track(user, "payment_completed", %{
          amount_bucket:
            amount_bucket(get_in(data, ["details", "totals"]), data["currency_code"]),
          currency: enum(data["currency_code"], @currencies),
          interval: enum(interval, @intervals),
          discounted: not is_nil(data["discount_id"]),
          origin: enum(data["origin"], @origins)
        })
    end

    :ok
  end

  # Once per adjustment id, the first time it is seen approved: a refund waits
  # in pending_approval, a chargeback is created approved and then updated
  # while it stays approved. Credits are plan-change prorations, not refunds.
  def forward_paddle_event(
        %{"event_type" => "adjustment." <> _, "data" => %{"status" => "approved"} = data},
        %Subscription{} = sub
      )
      when :erlang.map_get("action", data) in ["refund", "chargeback"] do
    if Idempotency.claim(:paddle_adjustment, data["id"]) do
      track_sub(sub, "refund_issued", %{
        action: data["action"],
        amount_bucket: amount_bucket(data["totals"], data["currency_code"]),
        currency: enum(data["currency_code"], @currencies),
        tier: sub.tier
      })
    else
      :ok
    end
  end

  def forward_paddle_event(_event, _result), do: :ok

  defp change_kind(from, prev_status, sub, data) do
    cond do
      get_in(data, ["scheduled_change", "action"]) == "cancel" -> "cancel_scheduled"
      rank(sub.tier) > rank(from) -> "upgrade"
      rank(sub.tier) < rank(from) -> "downgrade"
      prev_status in @lapsed and sub.status == "active" -> "reactivated"
      true -> nil
    end
  end

  defp rank(tier), do: Map.get(@tier_rank, tier, 0)

  # Paddle mints a new subscription (new started_at) on resubscribe, so a
  # reason given for an earlier subscription does not count for this one.
  defp started_at(data, sub) do
    case DateTime.from_iso8601(data["started_at"] || "") do
      {:ok, at, _} -> at
      _ -> sub.created_at
    end
  end

  defp cycle_props(data) do
    %{
      interval: enum(get_in(data, ["billing_cycle", "interval"]), @intervals),
      discounted: not is_nil(data["discount"])
    }
  end

  # Major-unit buckets, so a comp (0) never reads as a real payment.
  defp amount_bucket(totals, currency) do
    totals = totals || %{}

    with raw when is_binary(raw) <- totals["grand_total"] || totals["total"],
         {minor, ""} <- Integer.parse(raw) do
      major = if currency in @zero_decimal, do: minor, else: div(minor, 100)

      cond do
        minor == 0 -> "0"
        major < 10 -> "under_10"
        major < 25 -> "10_25"
        major < 50 -> "25_50"
        major < 100 -> "50_100"
        true -> "100_plus"
      end
    else
      _ -> "unknown"
    end
  end

  defp enum(value, allowed), do: if(value in allowed, do: value)

  # Paddle events carry the internal user id; resolve through the
  # Subscription row to the user. No email means no analytics id to join on,
  # so the event is dropped rather than sent as un-funnelable noise.
  defp track_sub(%Subscription{} = sub, event, props) do
    case Accounts.get_user(sub.user_id) do
      %{email: email} = user when is_binary(email) and byte_size(email) > 0 ->
        _ = Engram.Analytics.track(user, event, with_plan_traits(props, sub))
        :ok

      _ ->
        :ok
    end
  end

  # The plan rides as a person trait so it is right the moment it changes,
  # not a day later. Traits wait for the privacy policy that announces them,
  # same gate as the daily `PostHogPersonSync`.
  defp with_plan_traits(props, sub) do
    if PersonProperties.policy_in_effect?() do
      Map.put(props, "$set", %{
        "plan" => PersonProperties.plan(sub.tier, sub.status),
        "subscription_status" => sub.status
      })
    else
      props
    end
  end
end
