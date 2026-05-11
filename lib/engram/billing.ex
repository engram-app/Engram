defmodule Engram.Billing do
  @moduledoc """
  Billing context: Stripe checkout sessions, webhook processing, tier/trial queries,
  and plan-based limits enforcement.
  """

  import Ecto.Query
  alias Engram.Billing.Plan
  alias Engram.Billing.Subscription
  alias Engram.Billing.UserOverride
  alias Engram.Repo

  @default_limits %{
    "max_vaults" => 1,
    "max_storage_bytes" => 104_857_600,
    "cross_vault_search" => false,
    "vault_scoped_keys" => false
  }

  # ── Limits ────────────────────────────────────────────────────────

  @doc """
  Returns the effective limit for a given key for a user.

  Resolution order:
    1. user_overrides[key]
    2. plans[user.plan_id].limits[key]
    3. @default_limits[key]

  Uses explicit nil-checking (not ||) so that `false` values are honoured.
  """
  def effective_limit(user, key) do
    case override_value(user.id, key) do
      nil ->
        case plan_value(user, key) do
          nil -> Map.get(@default_limits, key)
          val -> val
        end

      val ->
        val
    end
  end

  @doc """
  Returns :ok if current_count is below the limit, or the limit is -1 (unlimited).
  Returns {:error, :limit_reached} when at or over the limit.
  """
  def check_limit(user, key, current_count) do
    case effective_limit(user, key) do
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
    if effective_limit(user, key) do
      :ok
    else
      {:error, :feature_not_available}
    end
  end

  # ── Private Limit Helpers ─────────────────────────────────────────

  # Returns the value from the user's override row for `key`, or nil if no override exists
  # or the key is absent in the overrides JSONB column.
  defp override_value(user_id, key) do
    Repo.one(
      from(o in UserOverride,
        where: o.user_id == ^user_id,
        select: fragment("?->?", o.overrides, ^key)
      ),
      skip_tenant_check: true
    )
    |> decode_json_value()
  end

  # Returns the value from the user's plan limits for `key`, or nil.
  defp plan_value(%{plan_id: nil}, _key), do: nil

  defp plan_value(%{plan_id: plan_id}, key) do
    Repo.one(
      from(p in Plan,
        where: p.id == ^plan_id,
        select: fragment("?->?", p.limits, ^key)
      ),
      skip_tenant_check: true
    )
    |> decode_json_value()
  end

  # Postgres returns JSON values as Postgrex decoded types:
  # integers → integer, booleans → boolean, nil (missing key) → nil.
  # No transformation needed — just return as-is.
  defp decode_json_value(value), do: value

  @trial_days 7

  # ── Tier & Status Queries ──────────────────────────────────────

  @doc """
  Returns the user's effective tier as an atom.
  Users without a subscription (or with a canceled one) are :none.
  """
  def tier(user) do
    case get_subscription(user) do
      %Subscription{status: status, tier: tier} when status in ~w(active past_due trialing) ->
        String.to_existing_atom(tier)

      _ ->
        :none
    end
  end

  @doc """
  Returns true if the user has an active, past_due, or trialing subscription.
  Users must start a trial (with card on file) via Stripe Checkout before syncing.
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

  @doc "Returns remaining trial days from the Stripe subscription, or 0."
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

  # ── Checkout Session ───────────────────────────────────────────

  @doc """
  Creates a Stripe Checkout Session. Includes a 7-day trial with card collection
  so the user can try before being charged.
  """
  def create_checkout_session(user, tier) when tier in ~w(starter pro) do
    price_id = price_id_for(tier)

    params = %{
      mode: :subscription,
      line_items: [%{price: price_id, quantity: 1}],
      customer_email: user.email,
      client_reference_id: to_string(user.id),
      metadata: %{"tier" => tier},
      subscription_data: %{trial_period_days: @trial_days},
      payment_method_collection: :always,
      success_url: success_url(),
      cancel_url: cancel_url()
    }

    case Stripe.Checkout.Session.create(params) do
      {:ok, session} -> {:ok, session.url}
      {:error, error} -> {:error, error}
    end
  end

  # ── Customer Portal ────────────────────────────────────────────

  def create_portal_session(user) do
    case get_subscription(user) do
      %Subscription{stripe_customer_id: customer_id} ->
        case Stripe.BillingPortal.Session.create(%{
               customer: customer_id,
               return_url: return_url()
             }) do
          {:ok, session} -> {:ok, session.url}
          {:error, error} -> {:error, error}
        end

      nil ->
        {:error, :no_subscription}
    end
  end

  # ── Webhook Event Processing ───────────────────────────────────

  def upsert_from_stripe_event(%{
        "type" => "checkout.session.completed",
        "data" => %{"object" => session}
      }) do
    %{
      "customer" => customer_id,
      "subscription" => subscription_id,
      "client_reference_id" => user_id_str,
      "metadata" => %{"tier" => tier}
    } = session

    user_id = String.to_integer(user_id_str)

    attrs = %{
      user_id: user_id,
      stripe_customer_id: customer_id,
      stripe_subscription_id: subscription_id,
      tier: tier,
      status: "trialing"
    }

    %Subscription{}
    |> Subscription.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace, [:stripe_customer_id, :stripe_subscription_id, :tier, :status, :updated_at]},
      conflict_target: :user_id,
      skip_tenant_check: true
    )
  end

  def upsert_from_stripe_event(%{
        "type" => type,
        "data" => %{"object" => sub_obj}
      })
      when type in ~w(customer.subscription.updated customer.subscription.deleted) do
    %{
      "id" => subscription_id,
      "status" => status,
      "current_period_end" => period_end_unix,
      "items" => %{"data" => [%{"price" => %{"id" => price_id}} | _]}
    } = sub_obj

    tier = tier_from_price_id(price_id)
    period_end = DateTime.from_unix!(period_end_unix)

    case Repo.one(
           from(s in Subscription, where: s.stripe_subscription_id == ^subscription_id),
           skip_tenant_check: true
         ) do
      %Subscription{} = sub ->
        sub
        |> Subscription.changeset(%{status: status, tier: tier, current_period_end: period_end})
        |> Repo.update(skip_tenant_check: true)

      nil ->
        {:error, :subscription_not_found}
    end
  end

  def upsert_from_stripe_event(_event), do: {:ok, :ignored}

  # ── Helpers ────────────────────────────────────────────────────

  defp price_id_for("starter"), do: Application.get_env(:engram, :stripe_starter_price_id)
  defp price_id_for("pro"), do: Application.get_env(:engram, :stripe_pro_price_id)

  defp tier_from_price_id(price_id) do
    cond do
      price_id == Application.get_env(:engram, :stripe_starter_price_id) -> "starter"
      price_id == Application.get_env(:engram, :stripe_pro_price_id) -> "pro"
      true -> "starter"
    end
  end

  defp success_url, do: EngramWeb.Endpoint.url() <> "/billing?success=true"
  defp cancel_url, do: EngramWeb.Endpoint.url() <> "/billing?canceled=true"
  defp return_url, do: EngramWeb.Endpoint.url() <> "/billing"
end
