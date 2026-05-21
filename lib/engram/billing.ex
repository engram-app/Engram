defmodule Engram.Billing do
  @moduledoc """
  Billing context: Paddle event processing, tier/trial queries, customer
  portal redirect, and plan-based limits enforcement. Checkout itself
  happens client-side in the Paddle.js overlay — the backend only reacts
  to webhooks.
  """

  import Ecto.Query
  alias Engram.Billing.LimitKeys
  alias Engram.Billing.Plan
  alias Engram.Billing.Subscription
  alias Engram.Billing.UserLimitOverride
  alias Engram.Repo

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
  end

  defp env_override_lookup(tier, key) do
    case Application.get_env(:engram, :plan_overrides, %{}) |> Map.fetch({tier, key}) do
      {:ok, v} -> {:hit, v}
      :error -> :miss
    end
  end

  defp plan_lookup(%{plan_id: nil}, _string_key), do: :miss

  defp plan_lookup(%{plan_id: id}, string_key) do
    Repo.one(
      from(p in Plan,
        where: p.id == ^id,
        select: fragment("?->?", p.limits, ^string_key)
      ),
      skip_tenant_check: true
    )
    |> wrap_lookup()
  end

  defp wrap_lookup(nil), do: :miss
  defp wrap_lookup(v), do: {:hit, v}

  # ── Tier & Status Queries ──────────────────────────────────────

  @doc """
  Returns the user's effective tier as an atom.
  Users without a subscription (or with a canceled one) are :free.
  """
  def tier(user) do
    case get_subscription(user) do
      %Subscription{status: status, tier: tier} when status in ~w(active past_due trialing) ->
        String.to_existing_atom(tier)

      _ ->
        :free
    end
  end

  @doc """
  Returns true if the user has an active, past_due, or trialing subscription.
  Users must start a 7-day trial (card on file) via the Paddle overlay
  before syncing — the trial is configured on the Paddle price.
  """
  def active?(user) do
    case get_subscription(user) do
      %Subscription{status: status} when status in ~w(active past_due trialing) ->
        true

      _ ->
        false
    end
  end

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
        Engram.Paddle.Client.impl().create_customer_portal_session(customer_id)

      _ ->
        {:error, :no_subscription}
    end
  end

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
        attrs = %{
          user_id: user_id,
          paddle_customer_id: data["customer_id"],
          paddle_subscription_id: data["id"],
          tier: tier_from_subscription(data),
          status: data["status"],
          current_period_end: parse_period_end(data),
          custom_data: data["custom_data"] || %{}
        }

        # Omit :custom_data from the replace list. Paddle delivers at-least-once,
        # so a retried subscription.created must NOT clobber the affiliate /
        # utm attribution captured on first delivery.
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

      :error ->
        {:error, :missing_user_id}
    end
  end

  def upsert_from_paddle_event(%{"event_type" => type, "data" => data})
      when type in ~w(subscription.activated subscription.updated subscription.past_due subscription.canceled) do
    subscription_id = data["id"]

    case Repo.one(
           from(s in Subscription, where: s.paddle_subscription_id == ^subscription_id),
           skip_tenant_check: true
         ) do
      %Subscription{} = sub ->
        sub
        |> Subscription.changeset(%{
          status: data["status"],
          tier: tier_from_subscription(data),
          current_period_end: parse_period_end(data)
        })
        |> Repo.update(skip_tenant_check: true)

      nil ->
        {:error, :subscription_not_found}
    end
  end

  def upsert_from_paddle_event(_event), do: {:ok, :ignored}

  # ── Helpers ────────────────────────────────────────────────────

  defp extract_user_id(%{"custom_data" => %{"user_id" => id}}) when is_integer(id), do: {:ok, id}

  defp extract_user_id(%{"custom_data" => %{"user_id" => id}}) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp extract_user_id(_), do: :error

  defp tier_from_subscription(%{"items" => [%{"price" => %{"id" => price_id}} | _]}),
    do: tier_from_price_id(price_id)

  defp tier_from_subscription(_), do: "starter"

  defp tier_from_price_id(price_id) do
    cond do
      price_id == Application.get_env(:engram, :paddle_starter_price_id) -> "starter"
      price_id == Application.get_env(:engram, :paddle_pro_price_id) -> "pro"
      true -> "starter"
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
