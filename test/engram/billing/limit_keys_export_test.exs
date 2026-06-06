defmodule Engram.Billing.LimitKeysExportTest do
  use ExUnit.Case, async: true

  alias Engram.Billing.LimitKeys

  describe "export limit keys" do
    test "account_exports_lifetime is defined with expected per-tier defaults" do
      assert LimitKeys.defined?(:account_exports_lifetime)
      assert LimitKeys.type(:account_exports_lifetime) == :integer
      assert LimitKeys.default_for(:account_exports_lifetime, :free) == 1
      assert LimitKeys.default_for(:account_exports_lifetime, :starter) == nil
      assert LimitKeys.default_for(:account_exports_lifetime, :pro) == nil
    end

    test "account_export_rate_per_24h is defined with expected per-tier defaults" do
      assert LimitKeys.defined?(:account_export_rate_per_24h)
      assert LimitKeys.type(:account_export_rate_per_24h) == :integer
      assert LimitKeys.default_for(:account_export_rate_per_24h, :free) == nil
      assert LimitKeys.default_for(:account_export_rate_per_24h, :starter) == 1
      assert LimitKeys.default_for(:account_export_rate_per_24h, :pro) == 1
    end

    test "account_export_max_bytes is defined with expected per-tier defaults" do
      assert LimitKeys.defined?(:account_export_max_bytes)
      assert LimitKeys.type(:account_export_max_bytes) == :integer
      assert LimitKeys.default_for(:account_export_max_bytes, :free) == 1_000_000_000
      assert LimitKeys.default_for(:account_export_max_bytes, :starter) == 200_000_000_000
      assert LimitKeys.default_for(:account_export_max_bytes, :pro) == 200_000_000_000
    end
  end
end
