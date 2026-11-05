defmodule Engram.Billing.SubscriptionTierDefaultTest do
  @moduledoc """
  `subscriptions.tier` shipped with `DEFAULT 'trial'`, a value its own
  `subscriptions_tier_check` (`free`/`starter`/`pro`) rejects. Every insert path
  sets `tier` (the changeset requires it), so the column carries no default: an
  insert that omits it is a NOT NULL error naming the column, not a CHECK
  violation that blames a value nobody wrote.
  """
  use Engram.DataCase, async: true

  import Engram.Factory

  alias Engram.Repo

  test "tier has no column default" do
    %{rows: [[default]]} =
      Repo.query!(
        "SELECT column_default FROM information_schema.columns " <>
          "WHERE table_name = 'subscriptions' AND column_name = 'tier'",
        [],
        skip_tenant_check: true
      )

    assert is_nil(default)
  end

  test "an insert that omits tier fails NOT NULL, not the tier CHECK" do
    user = insert(:user)

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "INSERT INTO subscriptions (user_id, paddle_customer_id, created_at, updated_at) " <>
            "VALUES ($1, 'ctm_default_probe', NOW(), NOW())",
          [Ecto.UUID.dump!(user.id)],
          skip_tenant_check: true
        )
      end

    assert error.postgres.code == :not_null_violation
    assert error.postgres.column == "tier"
  end
end
