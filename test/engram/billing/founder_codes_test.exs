defmodule Engram.Billing.FounderCodesTest do
  use Engram.DataCase, async: true

  alias Engram.Accounts.User
  alias Engram.Billing.FounderCodes
  alias Engram.Repo

  describe "redeem/2 — :founder" do
    test "first call stamps founder_code_redeemed_at" do
      user = insert(:user)

      assert {:ok, %User{founder_code_redeemed_at: %DateTime{}}} =
               FounderCodes.redeem(user, :founder)

      reloaded = Repo.get!(User, user.id, skip_tenant_check: true)
      assert %DateTime{} = reloaded.founder_code_redeemed_at
    end

    test "second call refuses" do
      user = insert(:user)
      {:ok, _} = FounderCodes.redeem(user, :founder)

      assert {:error, :already_redeemed} = FounderCodes.redeem(user, :founder)
    end

    test "concurrent redemption: exactly one succeeds" do
      user = insert(:user)

      results =
        1..10
        |> Task.async_stream(
          fn _ -> FounderCodes.redeem(user, :founder) end,
          max_concurrency: 10
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :already_redeemed}, &1)) == 9
    end
  end

  describe "redeem/2 — :og_grandfather" do
    test "first call stamps og_grandfather_redeemed_at" do
      user = insert(:user)

      assert {:ok, %User{og_grandfather_redeemed_at: %DateTime{}}} =
               FounderCodes.redeem(user, :og_grandfather)
    end

    test "second call refuses" do
      user = insert(:user)
      {:ok, _} = FounderCodes.redeem(user, :og_grandfather)

      assert {:error, :already_redeemed} = FounderCodes.redeem(user, :og_grandfather)
    end

    test "founder + og_grandfather are independent" do
      user = insert(:user)
      {:ok, _} = FounderCodes.redeem(user, :founder)

      # OG slot still open
      assert {:ok, _} = FounderCodes.redeem(user, :og_grandfather)
      # Founder slot still closed
      assert {:error, :already_redeemed} = FounderCodes.redeem(user, :founder)
    end
  end

  describe "redeem/2 — unknown code" do
    test "returns :unknown_code error" do
      user = insert(:user)
      assert {:error, :unknown_code} = FounderCodes.redeem(user, :bogus)
    end
  end

  describe "redeemed?/2" do
    test "reflects stamped state" do
      user = insert(:user)
      refute FounderCodes.redeemed?(user, :founder)
      refute FounderCodes.redeemed?(user, :og_grandfather)

      {:ok, user} = FounderCodes.redeem(user, :founder)
      assert FounderCodes.redeemed?(user, :founder)
      refute FounderCodes.redeemed?(user, :og_grandfather)
    end
  end
end
