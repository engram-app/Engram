defmodule Engram.Billing do
  @moduledoc """
  Billing context: Paddle event processing, tier/trial queries, customer
  portal redirect, and plan-based limits enforcement. Checkout itself
  happens client-side in the Paddle.js overlay — the backend only reacts
  to webhooks.
  """

  import Ecto.Query
  alias Engram.Billing.EntitlementCache
  alias Engram.Billing.LimitKeys
  alias Engram.Billing.PlanCache
  alias Engram.Billing.Subscription
  alias Engram.Billing.UserLimitOverride
  alias Engram.Logger.Metadata
  alias Engram.Paddle.Client
  alias Engram.Repo

  require Logger

  defmodule UnknownLimitKey do
    @moduledoc "Raised when a limit lookup uses an unknown atom or a string key."
    defexception [:key]

    def message(%{key: k}),
      do: "unknown limit key: #{inspect(k)} (atoms only, must be in LimitKeys.all/0)"
  end

  # ── Limits ────────────────────────────────────────────────────────

  @doc """
  Returns the effective limit for a given key for a user.

  Resolution order:
    1. user_overrides[key]
    2. plans[user.plan_id].limits[key]
    3. LimitKeys.default_for(key, tier)

  Uses explicit nil-checking (not ||) so that `false` values are honoured.
  Raises `Engram.Billing.UnknownLimitKey` for string keys or atoms not in
  `LimitKeys.all/0`.
  """
  def effective_limit(user, key) when is_atom(key) do
    unless LimitKeys.defined?(key), do: raise(UnknownLimitKey, key: key)

    if enforced?() do
      do_effective_limit(user, key)
    else
      :unlimited
    end
  end

  def effective_limit(_user, key), do: raise(UnknownLimitKey, key: key)

  defp enforced?, do: Application.get_env(:engram, :limits_enforced, true)

  defp do_effective_limit(user, key) do
    user_tier = tier(user)
    string_key = to_string(key)

    with :miss <- user_override_lookup(user.id, string_key),
         :miss <- env_override_lookup(user_tier, key),
         :miss <- plan_lookup(user, string_key) do
      LimitKeys.default_for(key, user_tier)
    else
      {:hit, v} -> v
    end
  end

  @doc """
  Returns :ok if current_count is below the limit, or the limit is -1 (unlimited).
  Returns {:error, :limit_reached} when at or over the limit.
  """
  def check_limit(user, key, current_count) do
    case effective_limit(user, key) do
      :unlimited -> :ok
      nil -> :ok
      -1 -> :ok
      limit when is_integer(limit) and current_count < limit -> :ok
      _ -> {:error, :limit_reached}
    end
  end

  @doc """
  Returns :ok if the boolean feature is enabled for the user.
  Returns {:error, :feature_not_available} otherwise.
  """
  def check_feature(user, key) do
    case effective_limit(user, key) do
      :unlimited -> :ok
      true -> :ok
      _ -> {:error, :feature_not_available}
    end
  end

  # ── Private Limit Helpers ─────────────────────────────────────────

  defp user_override_lookup(user_id, string_key) do
    # Read-through cache (60s TTL, hits AND misses): this lookup runs on
    # every effective_limit resolution and hot paths resolve several
    # limits per request, while override rows are rare admin grants.
    Engram.Billing.OverrideCache.fetch(user_id, string_key, fn ->
      now = DateTime.utc_now()

      Repo.one(
        from(o in UserLimitOverride,
          where:
            o.user_id == ^user_id and
              o.key == ^string_key and
              (is_nil(o.expires_at) or o.expires_at > ^now),
          select: fragment("?->'v'", o.value)
        ),
        skip_tenant_check: true
      )
      |> wrap_lookup()
    end)
  end

  defp env_override_lookup(tier, key) do
    case Application.get_env(:engram, :plan_overrides, %{}) |> Map.fetch({tier, key}) do
      {:ok, v} -> {:hit, v}
      :error -> :miss
    end
  end

  defp plan_lookup(%{plan_id: nil}, _string_key), do: :miss

  defp plan_lookup(%{plan_id: id}, string_key) do
    id
    |> PlanCache.limits()
    |> Map.get(string_key)
    |> wrap_lookup()
  end

  defp wrap_lookup(nil), do: :miss
  defp wrap_lookup(v), do: {:hit, v}

  # ── Tier & Status Queries ──────────────────────────────────────

  # Subscription statuses that entitle a user to their paid tier:
  #   * `active`   — paying, current.
  #   * `trialing` — paid plan with a deferred first charge (card-on-file);
  #     the whole point is full paid access during the window.
  #   * `past_due` — payment failed but Paddle is retrying within the
  #     dunning grace window; a transient card decline shouldn't strip
  #     features mid-cycle. (Data retention already treats past_due as
  #     paid — see `Engram.Workers.InactivityCleanup`.)
  # `paused`/`canceled` do NOT entitle: the subscription has lapsed, so the
  # user drops to Free until it recovers.
  @entitled_statuses ~w(active trialing past_due)

  @doc """
  Returns the user's effective tier as an atom in `[:free, :starter, :pro]`.

  An `active`, `trialing`, or `past_due` paid subscription resolves to
  `:starter` or `:pro` (see `@entitled_statuses` for the rationale — trials
  and dunning grace both keep access). Everyone else — un-onboarded users,
  self-host, paused / canceled subscriptions — resolves to `:free`. Always
  returns an atom (never `nil`); the un-onboarded path is gated upstream by
  `RequireOnboarding` but a Free default keeps `effective_limit/2` and
  `default_for/2` total.
  """
  @spec tier(Engram.Accounts.User.t()) :: :free | :starter | :pro
  def tier(%Engram.Accounts.User{} = user) do
    case get_subscription(user) do
      %Subscription{status: s, tier: "starter"} when s in @entitled_statuses -> :starter
      %Subscription{status: s, tier: "pro"} when s in @entitled_statuses -> :pro
      _ -> :free
    end
  end

  @doc """
  Plan/limit snapshot the Obsidian plugin needs to pre-gate attachments and
  recover after an upgrade. Sent on `user:{id}` channel join and on the
  `subscription_activated` broadcast. Numeric `:unlimited` limits serialize to
  `nil` (JSON null) so the wire shape stays `number | null`.
  """
  def plan_state(%Engram.Accounts.User{} = user) do
    %{
      tier: tier(user),
      attachments_text_only: effective_limit(user, :attachments_text_only) == true,
      max_file_bytes: numeric_limit(user, :max_file_bytes),
      attachment_bytes_cap: numeric_limit(user, :attachment_bytes_cap)
    }
  end

  defp numeric_limit(user, key) do
    case effective_limit(user, key) do
      :unlimited -> nil
      n when is_integer(n) -> n
      _ -> nil
    end
  end

  @doc """
  Returns the user's full, JSON-ready entitlement snapshot:

      %{tier: "free", limits: %{"notes_cap" => 10_000, "api_write_enabled" => false, ...}}

  Every `LimitKeys` key is resolved through `effective_limit/2` and normalized:
  integer caps stay integers (`:unlimited`/`nil`/`-1` → `null`), boolean
  features stay booleans (`:unlimited` → `true`, the "limits disabled" sense).

  Backed by `Engram.Billing.EntitlementCache` (24h TTL + explicit invalidation
  on subscription/override changes) so the bootstrap path serves the whole
  matrix from one ETS read. This is advisory UX state — server-side
  `check_limit/3` / `check_feature/2` remain the authoritative gates.
  """
  @spec capabilities(Engram.Accounts.User.t()) :: %{tier: String.t(), limits: map()}
  def capabilities(%Engram.Accounts.User{id: nil} = user), do: compute_capabilities(user)

  def capabilities(%Engram.Accounts.User{} = user) do
    EntitlementCache.fetch(user.id, fn -> compute_capabilities(user) end)
  end

  defp compute_capabilities(user) do
    limits =
      Map.new(LimitKeys.all(), fn key ->
        value = normalize_capability(LimitKeys.type(key), effective_limit(user, key))
        {Atom.to_string(key), value}
      end)

    %{tier: Atom.to_string(tier(user)), limits: limits}
  end

  # Boolean feature: :unlimited (enforcement off) opens the gate; explicit
  # true/false flows through; anything else fails closed.
  defp normalize_capability(:boolean, :unlimited), do: true
  defp normalize_capability(:boolean, true), do: true
  defp normalize_capability(:boolean, false), do: false
  defp normalize_capability(:boolean, _), do: false
  # Integer cap: "no cap" sentinels collapse to null for the wire.
  defp normalize_capability(:integer, :unlimited), do: nil
  defp normalize_capability(:integer, nil), do: nil
  defp normalize_capability(:integer, -1), do: nil
  defp normalize_capability(:integer, n) when is_integer(n), do: n
  defp normalize_capability(:integer, _), do: nil
  # String setting (e.g. per-tier query model id): the value flows through;
  # nil / :unlimited (enforcement off) / anything else → null on the wire.
  defp normalize_capability(:string, value) when is_binary(value), do: value
  defp normalize_capability(:string, _), do: nil

  @doc """
  Returns true when the user is not suspended. Tier defaults to `:free`
  for un-onboarded users — see `tier/1`. Account access is gated by
  suspension only; tier-based feature gating happens via
  `effective_limit/2` and `check_limit/3` / `check_feature/2`.
  """
  @spec active?(Engram.Accounts.User.t()) :: boolean()
  def active?(%Engram.Accounts.User{} = user) do
    is_nil(user.suspended_at)
  end

  @doc """
  Loads the user's subscription (or nil). Reuses an already-preloaded
  `:subscription` association when present so the auth pipeline can load it
  once per request and have `tier/1`, `active?/1`, and `effective_limit/2`
  share that single read instead of each issuing its own query.
  """
  def get_subscription(%{subscription: %Subscription{} = sub}), do: sub
  def get_subscription(%{subscription: nil}), do: nil
  # Non-persisted user (built but not inserted) — no row to load. Keeps
  # `tier/1` total over `build(:user, ...)` for unit tests that don't need
  # a DB round-trip.
  def get_subscription(%{id: nil}), do: nil

  def get_subscription(user) do
    Repo.one(
      from(s in Subscription, where: s.user_id == ^user.id),
      skip_tenant_check: true
    )
  end

  @doc "Returns remaining trial days from the Paddle subscription, or 0."
  def trial_days_remaining(user) do
    case get_subscription(user) do
      %Subscription{status: "trialing", current_period_end: period_end}
      when period_end != nil ->
        days = DateTime.diff(period_end, DateTime.utc_now(), :day)
        max(days, 0)

      _ ->
        0
    end
  end

  # ── Customer Portal ────────────────────────────────────────────

  @doc """
  Create a Paddle customer-portal session for the user's subscription and
  return the URL. Returns `{:error, :no_subscription}` if the user has no
  subscription yet.
  """
  def create_portal_session(user) do
    case get_subscription(user) do
      %Subscription{paddle_customer_id: customer_id} when is_binary(customer_id) ->
        Client.impl().create_customer_portal_session(customer_id)

      _ ->
        {:error, :no_subscription}
    end
  end

  # ── Live Paddle Read-Through (billing settings surface) ────────
  #
  # The subscription detail, payment method, and invoice history are fetched
  # live from Paddle per page load rather than persisted — the webhook row
  # only carries tier/status/period-end, and mirroring the rest would couple
  # us to stale data. All of these short-circuit to {:error, :no_subscription}
  # for users without a Paddle subscription.

  @doc """
  Fetch and normalize the user's live subscription detail: next bill, amount
  (Paddle minor units + currency for the frontend to format), billing cycle,
  and any pending `scheduled_change` (cancel/pause/plan change).
  """
  def subscription_detail(user) do
    with_paddle_subscription(user, fn sub ->
      case Client.impl().get_subscription(sub.paddle_subscription_id) do
        {:ok, raw} -> {:ok, normalize_subscription(raw)}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Fetch the user's transaction history plus the card behind the most recent
  card payment. Returns `%{payment_method: pm | nil, transactions: [...]}`.
  """
  def billing_history(user) do
    with_paddle_subscription(user, fn sub ->
      case Client.impl().list_transactions(sub.paddle_subscription_id) do
        {:ok, txns} ->
          {:ok,
           %{
             payment_method: payment_method_from(txns),
             transactions: Enum.map(txns, &normalize_transaction/1)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Mint the hosted invoice URL for one of the user's transactions. Verifies the
  transaction belongs to the user's subscription before minting (IDOR guard) —
  Paddle transaction IDs are otherwise enumerable across customers.
  """
  def transaction_invoice_url(user, transaction_id) do
    with_paddle_subscription(user, fn sub ->
      case Client.impl().list_transactions(sub.paddle_subscription_id) do
        {:ok, txns} ->
          if Enum.any?(txns, &(&1["id"] == transaction_id)) do
            Client.impl().get_transaction_invoice(transaction_id)
          else
            {:error, :not_found}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Resolve a customer-portal deep link for a given action: `"cancel"`,
  `"update_payment"`, or anything else (→ the general overview URL).
  """
  def portal_action_url(user, action) do
    case get_subscription(user) do
      %Subscription{paddle_customer_id: customer_id} = sub when is_binary(customer_id) ->
        case Client.impl().get_portal_session(customer_id) do
          {:ok, urls} -> {:ok, pick_portal_url(urls, action, sub.paddle_subscription_id)}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :no_subscription}
    end
  end

  @doc """
  Mint a transaction for an in-app payment-method update. Returns the Paddle
  transaction id for `Paddle.Checkout.open({ transactionId })`.
  """
  def update_payment_transaction(user) do
    with_paddle_subscription(user, fn sub ->
      case Client.impl().get_update_payment_transaction(sub.paddle_subscription_id) do
        {:ok, %{"id" => transaction_id}} -> {:ok, transaction_id}
        {:ok, _} -> {:error, :invalid_response}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp with_paddle_subscription(user, fun) do
    case get_subscription(user) do
      %Subscription{paddle_subscription_id: sub_id} = sub when is_binary(sub_id) ->
        fun.(sub)

      _ ->
        {:error, :no_subscription}
    end
  end

  defp normalize_subscription(raw) do
    %{
      next_billed_at: raw["next_billed_at"],
      amount: get_in(raw, ["recurring_transaction_details", "totals", "total"]),
      currency: raw["currency_code"],
      billing_cycle: normalize_cycle(raw["billing_cycle"]),
      scheduled_change: normalize_scheduled_change(raw["scheduled_change"])
    }
  end

  defp normalize_cycle(%{"interval" => interval, "frequency" => frequency}),
    do: %{interval: interval, frequency: frequency}

  defp normalize_cycle(_), do: nil

  defp normalize_scheduled_change(%{"action" => action, "effective_at" => effective_at}),
    do: %{action: action, effective_at: effective_at}

  defp normalize_scheduled_change(_), do: nil

  defp normalize_transaction(t) do
    %{
      id: t["id"],
      billed_at: t["billed_at"] || t["created_at"],
      amount: get_in(t, ["details", "totals", "grand_total"]),
      currency: get_in(t, ["details", "totals", "currency_code"]),
      status: t["status"],
      invoice_id: t["invoice_id"]
    }
  end

  defp payment_method_from(txns) do
    Enum.find_value(txns, fn t ->
      case t["payments"] do
        [%{"method_details" => %{"card" => card} = md} | _] when is_map(card) ->
          %{
            type: md["type"],
            card_brand: card["type"],
            last4: card["last4"],
            exp_month: card["expiry_month"],
            exp_year: card["expiry_year"]
          }

        _ ->
          nil
      end
    end)
  end

  defp pick_portal_url(urls, action, sub_id) do
    sub_urls = Enum.find(urls["subscriptions"] || [], &(&1["id"] == sub_id)) || %{}

    case action do
      "cancel" -> sub_urls["cancel_subscription"] || overview_url(urls)
      "update_payment" -> sub_urls["update_subscription_payment_method"] || overview_url(urls)
      _ -> overview_url(urls)
    end
  end

  defp overview_url(urls), do: get_in(urls, ["general", "overview"])

  # ── Webhook Event Processing ───────────────────────────────────

  @doc """
  Upsert a Subscription row from a verified Paddle notification.

  Handles `subscription.created` (insert), `subscription.activated`,
  `subscription.updated`, `subscription.past_due`, and
  `subscription.canceled` (update by paddle_subscription_id). All other
  event types are accepted but ignored.
  """
  def upsert_from_paddle_event(%{"event_type" => "subscription.created", "data" => data}) do
    case extract_user_id(data) do
      {:ok, user_id} ->
        base_attrs = %{
          user_id: user_id,
          paddle_customer_id: data["customer_id"],
          paddle_subscription_id: data["id"],
          status: data["status"],
          current_period_end: parse_period_end(data),
          custom_data: data["custom_data"] || %{}
        }

        attrs =
          case tier_from_subscription(data) do
            {:ok, tier} ->
              Map.put(base_attrs, :tier, Atom.to_string(tier))

            {:error, :unknown_price_id} ->
              _ =
                Sentry.capture_message("Unknown Paddle price_id, tier unchanged",
                  extra: %{user_id: user_id, payload_keys: Map.keys(data)}
                )

              base_attrs
          end

        # Omit :custom_data from the replace list. Paddle delivers at-least-once,
        # so a retried subscription.created must NOT clobber the affiliate /
        # utm attribution captured on first delivery.
        result =
          %Subscription{}
          |> Subscription.changeset(attrs)
          |> Repo.insert(
            on_conflict:
              {:replace,
               [
                 :paddle_customer_id,
                 :paddle_subscription_id,
                 :tier,
                 :status,
                 :current_period_end,
                 :updated_at
               ]},
            conflict_target: :user_id,
            skip_tenant_check: true
          )

        case result do
          {:ok, sub} ->
            broadcast_subscription_activated(user_id, sub)
            {:ok, sub}

          err ->
            err
        end

      :error ->
        {:error, :missing_user_id}
    end
  end

  def upsert_from_paddle_event(%{"event_type" => "subscription.canceled", "data" => data}) do
    subscription_id = data["id"]

    case Repo.one(
           from(s in Subscription, where: s.paddle_subscription_id == ^subscription_id),
           skip_tenant_check: true
         ) do
      %Subscription{} = sub ->
        sub_with_user = Repo.preload(sub, :user, skip_tenant_check: true)
        user = sub_with_user.user
        prev_tier = if user, do: tier(user), else: :free

        base_attrs = %{
          status: data["status"],
          current_period_end: parse_period_end(data)
        }

        update_attrs =
          case tier_from_subscription(data) do
            {:ok, tier_atom} ->
              Map.put(base_attrs, :tier, Atom.to_string(tier_atom))

            {:error, :unknown_price_id} ->
              _ =
                Sentry.capture_message("Unknown Paddle price_id, tier unchanged",
                  extra: %{user_id: sub.user_id, payload_keys: Map.keys(data)}
                )

              base_attrs
          end

        # Flip the user to Free at cancellation (period end per Paddle's engine).
        # `free_tier_accepted_at` is stamped only when nil so a user who had
        # originally accepted Free, upgraded, then canceled keeps the original
        # acceptance timestamp. Wrap both writes in a transaction so a partial
        # failure rolls back together.
        result =
          Repo.transaction(fn ->
            updated_sub =
              sub
              |> Subscription.changeset(update_attrs)
              |> Repo.update!(skip_tenant_check: true)

            if user && is_nil(user.free_tier_accepted_at) do
              user
              |> Ecto.Changeset.change(free_tier_accepted_at: DateTime.utc_now())
              |> Repo.update!()
            end

            updated_sub
          end)

        case result do
          {:ok, updated} ->
            broadcast_subscription_activated(updated.user_id, updated)

            # Force-disconnect open sockets so the next reconnect re-runs the
            # tier gate with the canceled subscription. Mirrors the behaviour
            # in subscription.updated/activated when tier or status flips.
            Engram.Auth.SessionInvalidator.disconnect_user(updated.user_id)

            if user do
              :telemetry.execute(
                [:engram, :tier_downgraded],
                %{count: 1},
                %{user_id: user.id, from: prev_tier, to: :free}
              )
            end

            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end

      nil ->
        {:error, :subscription_not_found}
    end
  end

  def upsert_from_paddle_event(%{"event_type" => type, "data" => data})
      when type in ~w(subscription.activated subscription.updated subscription.past_due) do
    subscription_id = data["id"]

    case Repo.one(
           from(s in Subscription, where: s.paddle_subscription_id == ^subscription_id),
           skip_tenant_check: true
         ) do
      %Subscription{tier: prev_tier, status: prev_status} = sub ->
        base_attrs = %{
          status: data["status"],
          current_period_end: parse_period_end(data)
        }

        update_attrs =
          case tier_from_subscription(data) do
            {:ok, tier} ->
              Map.put(base_attrs, :tier, Atom.to_string(tier))

            {:error, :unknown_price_id} ->
              _ =
                Sentry.capture_message("Unknown Paddle price_id, tier unchanged",
                  extra: %{user_id: sub.user_id, payload_keys: Map.keys(data)}
                )

              base_attrs
          end

        result =
          sub
          |> Subscription.changeset(update_attrs)
          |> Repo.update(skip_tenant_check: true)

        case result do
          {:ok, updated} ->
            # Same broadcast event for activated/updated — the frontend
            # listener re-fetches /onboarding/status to decide what to do,
            # so plan changes and trial→active flips both push downstream UI.
            broadcast_subscription_activated(updated.user_id, updated)

            # Realtime sync (and other tier-gated features) are evaluated at
            # channel-join, so an open SyncChannel keeps streaming after a
            # tier or status change. Force-disconnect when either changed so
            # the next reconnect re-runs the gate with the fresh subscription.
            if updated.tier != prev_tier or updated.status != prev_status do
              Engram.Auth.SessionInvalidator.disconnect_user(updated.user_id)
            end

            {:ok, updated}

          err ->
            err
        end

      nil ->
        {:error, :subscription_not_found}
    end
  end

  def upsert_from_paddle_event(_event), do: {:ok, :ignored}

  # Notify the user's open browser tabs that their subscription state
  # changed server-side, so the activation overlay can hand off to the
  # next onboarding step (or settings billing UI can refresh) in
  # milliseconds rather than waiting on a polling loop. Mirrors the
  # vault_created broadcast in Engram.Vaults. Fire-and-forget: if nobody
  # is listening, Phoenix.PubSub drops it.
  defp broadcast_subscription_activated(user_id, %Subscription{} = sub) do
    # Chokepoint for every subscription mutation (created/updated/canceled):
    # tier/status flips can change the onboarding gate's subscription_ok,
    # so the cached pass verdict must re-derive.
    :ok = Engram.Onboarding.GateCache.evict(user_id)

    # Same flip changes the user's tier and therefore their entire resolved
    # limit matrix — drop the cached entitlement snapshot so it re-derives.
    :ok = EntitlementCache.evict(user_id)

    # Carry the full plan snapshot so the plugin can re-gate attachments the
    # instant the subscription flips, without a follow-up fetch. `tier` stays
    # the string form (`sub.tier`, e.g. "pro") that the web frontend type and
    # existing consumers expect, so we take only the attachment limit fields
    # from plan_state (allowlist) — a future field added to plan_state/1 can't
    # silently leak into the broadcast, and this branch stays symmetric with
    # the fallback below. The attachment limit fields are the new payload.
    plan_fields =
      case Engram.Accounts.get_user(user_id) do
        %Engram.Accounts.User{} = u ->
          plan_state(u)
          |> Map.take([:attachments_text_only, :max_file_bytes, :attachment_bytes_cap])

        _ ->
          %{attachments_text_only: nil, max_file_bytes: nil, attachment_bytes_cap: nil}
      end

    _ =
      EngramWeb.Endpoint.broadcast(
        "user:#{user_id}",
        "subscription_activated",
        Map.merge(plan_fields, %{
          tier: sub.tier,
          status: sub.status,
          subscription_id: sub.paddle_subscription_id
        })
      )

    :ok
  end

  # ── Helpers ────────────────────────────────────────────────────

  defp extract_user_id(%{"custom_data" => %{"user_id" => id}}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp extract_user_id(_), do: :error

  @doc """
  Resolve a tier (`:starter` | `:pro`) from a Paddle subscription data
  map. Returns `{:error, :unknown_price_id}` for unknown or missing
  prices (logged loudly via `Logger.error`) so the caller can decide what
  to do — typically: do NOT mutate the user's tier, and alert ops. This
  avoids silently downgrading a paying user to free when Paddle sends a
  price_id we don't recognize (e.g., a mis-configured env var).
  """
  @spec tier_from_subscription(map()) ::
          {:ok, :starter | :pro} | {:error, :unknown_price_id}
  def tier_from_subscription(%{"items" => [%{"price" => %{"id" => price_id}} | _]}) do
    tier_from_price_id(price_id)
  end

  def tier_from_subscription(other) do
    Logger.error(
      "paddle subscription missing items[0].price.id",
      Metadata.with_category(:error, :billing, payload_keys: Map.keys(other || %{}))
    )

    {:error, :unknown_price_id}
  end

  defp tier_from_price_id(price_id) do
    cond do
      price_id == Application.get_env(:engram, :paddle_starter_monthly_price_id) ->
        {:ok, :starter}

      price_id == Application.get_env(:engram, :paddle_starter_annual_price_id) ->
        {:ok, :starter}

      price_id == Application.get_env(:engram, :paddle_pro_monthly_price_id) ->
        {:ok, :pro}

      price_id == Application.get_env(:engram, :paddle_pro_annual_price_id) ->
        {:ok, :pro}

      true ->
        log_unknown_price_id_once(price_id)
        {:error, :unknown_price_id}
    end
  end

  # Dedupe per-process. Reconciliation iterates every Paddle sub and
  # webhook handlers run in their own request process — without this
  # guard, a misconfigured PADDLE_*_PRICE_ID env var would fire N logs
  # per reconciliation cycle (one per Paddle sub) and burn Sentry quota.
  # With the guard: one log per unique unknown price ID per process,
  # which is the actionable signal.
  defp log_unknown_price_id_once(price_id) do
    seen = Process.get(:engram_unknown_price_ids_seen, MapSet.new())

    unless MapSet.member?(seen, price_id) do
      Logger.error(
        "paddle_unknown_price_id",
        Metadata.with_category(:error, :billing,
          reason_label: :unknown_price_id,
          paddle_price_id: price_id
        )
      )

      Process.put(:engram_unknown_price_ids_seen, MapSet.put(seen, price_id))
    end
  end

  defp parse_period_end(%{"current_billing_period" => %{"ends_at" => ts}}) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_period_end(_), do: nil
end
