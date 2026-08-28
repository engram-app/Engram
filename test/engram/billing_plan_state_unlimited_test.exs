defmodule Engram.BillingPlanStateUnlimitedTest do
  # async: false — flips the global :limits_enforced env so effective_limit/2
  # resolves the atom :unlimited (the only path that exercises the
  # :unlimited -> nil branch of numeric_limit/2). Lives in its own module so the
  # global flip never races the async billing_test.exs suite.
  use Engram.DataCase, async: false

  alias Engram.Billing

  describe "plan_state/1 with limits unenforced" do
    test "unlimited numeric limits serialize to nil" do
      prev = Application.get_env(:engram, :limits_enforced)
      Application.put_env(:engram, :limits_enforced, false)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:engram, :limits_enforced),
          else: Application.put_env(:engram, :limits_enforced, prev)
      end)

      state = Billing.plan_state(build(:user, free_tier_accepted_at: nil))

      assert state.max_file_bytes == nil
      assert state.attachment_bytes_cap == nil
      assert state.indexed_notes_cap == nil
    end
  end

  describe "plan_state/1 numeric limits" do
    test "free carries the real indexed-note cap" do
      state = Billing.plan_state(insert(:user))
      assert state.indexed_notes_cap == 2_000
    end

    test "a negative override serializes to nil, not to a literal negative cap" do
      user = insert(:user)

      Engram.Repo.insert!(%Engram.Billing.UserLimitOverride{
        user_id: user.id,
        key: "indexed_notes_cap",
        value: %{"v" => -1},
        reason: "test",
        set_by: "test"
      })

      Engram.Billing.OverrideCache.evict(user.id)

      # -1 is the "unlimited" sentinel. Passing it through would make every
      # client responsible for knowing that, and a client that does not invert
      # the limit: "-1 notes indexed" reads as nothing searchable on the MOST
      # permissive setting. Same class as attachments_text_only blocking
      # self-host attachments.
      assert Billing.plan_state(user).indexed_notes_cap == nil
    end
  end
end
