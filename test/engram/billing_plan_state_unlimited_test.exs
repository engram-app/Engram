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
    end
  end
end
