defmodule Engram.Billing.LimitKeysTest do
  use ExUnit.Case, async: true

  alias Engram.Billing.LimitKeys

  describe "all/0" do
    test "returns the 25 catalog keys" do
      keys = LimitKeys.all()
      assert length(keys) == 25
      assert :notes_cap in keys
      assert :vaults_cap in keys
      assert :reranker_enabled in keys
      assert :cross_vault_search in keys
      assert :vault_scoped_keys in keys
    end
  end

  describe "defined?/1" do
    test "true for every catalog key" do
      for key <- LimitKeys.all() do
        assert LimitKeys.defined?(key), "expected #{inspect(key)} to be defined"
      end
    end

    test "false for unknown atom" do
      refute LimitKeys.defined?(:bogus)
    end

    test "false for non-atom (string)" do
      refute LimitKeys.defined?("notes_cap")
    end
  end

  describe "type/1" do
    test "returns :integer for numeric keys" do
      assert LimitKeys.type(:notes_cap) == :integer
      assert LimitKeys.type(:vaults_cap) == :integer
      assert LimitKeys.type(:attachment_bytes_cap) == :integer
    end

    test "returns :boolean for feature flags" do
      assert LimitKeys.type(:realtime_sync_enabled) == :boolean
      assert LimitKeys.type(:reranker_enabled) == :boolean
      assert LimitKeys.type(:api_write_enabled) == :boolean
    end

    test "raises FunctionClauseError on unknown key" do
      assert_raise FunctionClauseError, fn -> LimitKeys.type(:bogus) end
    end
  end

  describe "default_for/2 — full matrix pin" do
    test "free tier matrix matches spec §9.2" do
      assert LimitKeys.default_for(:notes_cap, :free) == 10_000
      assert LimitKeys.default_for(:vaults_cap, :free) == 1
      assert LimitKeys.default_for(:attachment_bytes_cap, :free) == 1_073_741_824
      assert LimitKeys.default_for(:max_file_bytes, :free) == 10_485_760
      assert LimitKeys.default_for(:lifetime_embed_token_cap, :free) == 20_000_000
      assert LimitKeys.default_for(:concurrent_devices, :free) == 1
      assert LimitKeys.default_for(:device_swap_cooldown_hours, :free) == 24
      assert LimitKeys.default_for(:realtime_sync_enabled, :free) == false
      assert LimitKeys.default_for(:ai_conversations_per_day, :free) == 5
      assert LimitKeys.default_for(:ai_queries_per_conversation, :free) == 50
      assert LimitKeys.default_for(:ai_queries_per_day, :free) == nil
      assert LimitKeys.default_for(:conversation_window_minutes, :free) == 30
      assert LimitKeys.default_for(:reranker_enabled, :free) == false
      assert LimitKeys.default_for(:api_write_enabled, :free) == false
      assert LimitKeys.default_for(:api_rps_cap, :free) == 0
      assert LimitKeys.default_for(:inactivity_warn_60_days, :free) == true
      assert LimitKeys.default_for(:inactivity_delete_days, :free) == 90
    end

    test "starter tier matrix matches spec §9.2" do
      assert LimitKeys.default_for(:notes_cap, :starter) == 50_000
      assert LimitKeys.default_for(:vaults_cap, :starter) == 5
      assert LimitKeys.default_for(:attachment_bytes_cap, :starter) == 3_221_225_472
      assert LimitKeys.default_for(:max_file_bytes, :starter) == 209_715_200
      assert LimitKeys.default_for(:lifetime_embed_token_cap, :starter) == nil
      assert LimitKeys.default_for(:realtime_sync_enabled, :starter) == true
      assert LimitKeys.default_for(:ai_queries_per_day, :starter) == 500
      assert LimitKeys.default_for(:api_rps_cap, :starter) == 10
    end

    test "pro tier matrix matches spec §9.2" do
      assert LimitKeys.default_for(:notes_cap, :pro) == nil
      assert LimitKeys.default_for(:vaults_cap, :pro) == 15
      assert LimitKeys.default_for(:attachment_bytes_cap, :pro) == 16_106_127_360
      assert LimitKeys.default_for(:max_file_bytes, :pro) == 524_288_000
      assert LimitKeys.default_for(:reranker_enabled, :pro) == true
      assert LimitKeys.default_for(:ai_queries_per_day, :pro) == 10_000
      assert LimitKeys.default_for(:api_rps_cap, :pro) == 30
    end

    test "raises FunctionClauseError on unknown tier" do
      assert_raise FunctionClauseError, fn -> LimitKeys.default_for(:notes_cap, :enterprise) end
    end

    test "raises FunctionClauseError on unknown key" do
      assert_raise FunctionClauseError, fn -> LimitKeys.default_for(:bogus, :free) end
    end
  end

  describe "env_var_names/0" do
    test "emits 75 tuples (25 keys × 3 tiers)" do
      tuples = LimitKeys.env_var_names()
      assert length(tuples) == 75
    end

    test "includes ENGRAM_FREE_NOTES_CAP" do
      assert {:free, :notes_cap, "ENGRAM_FREE_NOTES_CAP"} in LimitKeys.env_var_names()
    end

    test "includes ENGRAM_PRO_RERANKER_ENABLED" do
      assert {:pro, :reranker_enabled, "ENGRAM_PRO_RERANKER_ENABLED"} in LimitKeys.env_var_names()
    end
  end

  describe "tiers/0" do
    test "returns the three tier atoms" do
      assert LimitKeys.tiers() == [:free, :starter, :pro]
    end
  end

  describe "connections caps" do
    test "obsidian_connections_cap is 1 on free, nil on paid" do
      assert LimitKeys.defined?(:obsidian_connections_cap)
      assert LimitKeys.default_for(:obsidian_connections_cap, :free) == 1
      assert LimitKeys.default_for(:obsidian_connections_cap, :starter) == nil
      assert LimitKeys.default_for(:obsidian_connections_cap, :pro) == nil
    end

    test "mcp_connections_cap is 1 on free, nil on paid" do
      assert LimitKeys.defined?(:mcp_connections_cap)
      assert LimitKeys.default_for(:mcp_connections_cap, :free) == 1
      assert LimitKeys.default_for(:mcp_connections_cap, :starter) == nil
      assert LimitKeys.default_for(:mcp_connections_cap, :pro) == nil
    end
  end

  test "attachments_enabled key is defined for all three tiers" do
    assert LimitKeys.defined?(:attachments_enabled)
    assert LimitKeys.type(:attachments_enabled) == :boolean
    assert LimitKeys.default_for(:attachments_enabled, :free) == false
    assert LimitKeys.default_for(:attachments_enabled, :starter) == true
    assert LimitKeys.default_for(:attachments_enabled, :pro) == true
  end
end
