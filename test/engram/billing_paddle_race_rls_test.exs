defmodule Engram.BillingPaddleRaceRlsTest do
  @moduledoc """
  Pins the #2312 race recovery's re-read under ENFORCED row-level security.

  When a subscription insert loses a race on `paddle_subscription_id`, the
  insert path re-reads the row by paddle id to learn who owns it. That read
  runs after `with_tenant!/2` has returned, so no tenant is set, and only the
  `subscriptions_discovery` SELECT policy admits it. The rest of the suite
  connects as a superuser, which bypasses RLS and would pass even if the
  policy filtered the row out (the re-read would then find nothing and the
  event would come back as a retryable changeset instead of being refused).
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Billing
  alias Engram.Billing.Subscription
  alias Engram.Repo

  setup do
    owner = insert(:user)
    other = insert(:user)
    {:ok, _} = Billing.upsert_from_paddle_event(event(owner, "2026-10-29T06:17:00Z"))
    %{owner: owner, other: other}
  end

  # Control: the role drop engaged. Under another user's tenant the owner's
  # row is filtered out, so a green below is not a superuser bypass.
  test "control: engram_app under another tenant sees zero subscription rows", %{other: other} do
    assert {:returned, []} =
             as_prod_role(fn -> Repo.with_tenant!(other.id, fn -> Repo.all(Subscription) end) end)
  end

  test "the re-read finds another user's row, so the event is refused", %{other: other} do
    assert {:returned, {:error, :paddle_subscription_owned_by_other_user}} =
             as_prod_role(fn ->
               Billing.upsert_from_paddle_event(event(other, "2026-10-29T06:17:01Z"))
             end)
  end

  defp event(user, occurred_at) do
    %{
      "event_type" => "subscription.created",
      "occurred_at" => occurred_at,
      "data" => %{
        "id" => "sub_race_rls",
        "status" => "active",
        "customer_id" => "ctm_race_rls",
        "items" => [%{"price" => %{"id" => "pri_pro_monthly_test"}}],
        "current_billing_period" => %{"ends_at" => "2026-11-29T00:00:00Z"},
        "custom_data" => checkout_custom_data(user.id)
      }
    }
  end
end
