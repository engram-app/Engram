defmodule Engram.Billing.LegacyOverrideTranslationTest do
  @moduledoc """
  Pins the data transform in
  `priv/repo/migrations/20260831120000_translate_legacy_limit_overrides_migrate_data.exs`.

  A migration that runs cleanly proves nothing about whether it moved the data
  correctly, and this one inverts a boolean — the single easiest thing to get
  backwards. Getting it backwards is silent and harmful in both directions: an
  operator who suppressed dunning starts mailing account-deletion warnings, or
  an operator who restricted attachments has that restriction lifted.

  The SQL is duplicated from the migration rather than shared. A migration is
  frozen history and must not import from application code that later changes
  shape; the assertion that matters is the OUTCOME (operator intent survives),
  which is what these tests check through `Billing`, not through the SQL.
  """
  use Engram.DataCase, async: false

  import Engram.Factory

  alias Engram.Billing
  alias Engram.Repo

  defp translate!(legacy_key, current_key) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by, set_at)
      SELECT user_id,
             $1,
             jsonb_build_object('v', NOT (value->>'v')::boolean),
             COALESCE(reason, '') || ' [migrated from ' || $2 || ']',
             set_by,
             set_at
        FROM user_limit_overrides
       WHERE key = $2
         AND jsonb_typeof(value->'v') = 'boolean'
      ON CONFLICT (user_id, key) DO NOTHING
      """,
      [current_key, legacy_key]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM user_limit_overrides WHERE key = $1",
      [legacy_key]
    )
  end

  defp reload(user), do: Repo.get!(Engram.Accounts.User, user.id) |> Repo.preload(:subscription)

  test "an operator's dunning suppression survives the rename" do
    user = insert(:user)

    # The retired spelling was restriction-shaped: false == "do not warn".
    insert(:user_limit_override,
      user: user,
      key: "inactivity_warn_60_days",
      value: %{"v" => false}
    )

    translate!("inactivity_warn_60_days", "inactivity_warnings_exempt")

    # Grant-shaped now: true == "exempt from warnings". Same intent, opposite
    # spelling. Without the flip this user starts receiving the 60- and 80-day
    # account-deletion warning emails.
    assert Billing.inactivity_warnings_exempt?(reload(user))
    assert Billing.effective_limit(reload(user), :inactivity_warnings_exempt) == true
  end

  test "an operator's attachment restriction survives the rename" do
    user = insert(:user)

    # Restriction-shaped: true == "text only", i.e. images and PDFs denied.
    insert(:user_limit_override,
      user: user,
      key: "attachments_text_only",
      value: %{"v" => true}
    )

    translate!("attachments_text_only", "attachments_all_types")

    # Grant-shaped: false == "not allowed all types". Without the flip the
    # restriction is silently lifted, since every tier defaults to true.
    refute Billing.attachments_all_types?(reload(user))
  end

  test "a row already under the current spelling wins over the legacy one" do
    user = insert(:user)

    insert(:user_limit_override,
      user: user,
      key: "attachments_all_types",
      value: %{"v" => true}
    )

    insert(:user_limit_override,
      user: user,
      key: "attachments_text_only",
      value: %{"v" => true}
    )

    translate!("attachments_text_only", "attachments_all_types")

    # ON CONFLICT DO NOTHING: the explicit current-spelling row is authoritative
    # and the legacy row is dropped, not merged.
    assert Billing.attachments_all_types?(reload(user))
    assert Repo.aggregate(legacy_rows("attachments_text_only"), :count) == 0
  end

  test "the legacy rows are gone afterwards" do
    user = insert(:user)

    insert(:user_limit_override,
      user: user,
      key: "inactivity_warn_60_days",
      value: %{"v" => false}
    )

    translate!("inactivity_warn_60_days", "inactivity_warnings_exempt")

    # Leaving them would be harmless today but they are unreadable: the keys are
    # no longer in LimitKeys and `UserLimitOverride.changeset/2` rejects them.
    assert Repo.aggregate(legacy_rows("inactivity_warn_60_days"), :count) == 0
  end

  defp legacy_rows(key) do
    import Ecto.Query
    from(o in "user_limit_overrides", where: o.key == ^key)
  end
end
