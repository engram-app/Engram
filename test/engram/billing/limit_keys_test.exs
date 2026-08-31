defmodule Engram.Billing.LimitKeysTest do
  use ExUnit.Case, async: true

  alias Engram.Billing.LimitKeys

  describe "all/0" do
    test "returns the 32 catalog keys" do
      keys = LimitKeys.all()
      assert length(keys) == 32
      assert :notes_cap in keys
      assert :vaults_cap in keys
      assert :reranker_enabled in keys
      assert :cross_vault_search in keys
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
      assert LimitKeys.default_for(:concurrent_devices, :free) == 2
      assert LimitKeys.default_for(:device_swap_cooldown_hours, :free) == 24
      assert LimitKeys.default_for(:external_ai_searches_per_day, :free) == 15
      assert LimitKeys.default_for(:inapp_searches_per_day, :free) == 60
      assert LimitKeys.default_for(:ai_conversations_per_day, :free) == 5
      assert LimitKeys.default_for(:ai_queries_per_conversation, :free) == 50
      assert LimitKeys.default_for(:ai_queries_per_day, :free) == nil
      assert LimitKeys.default_for(:conversation_window_minutes, :free) == 30
      assert LimitKeys.default_for(:reranker_enabled, :free) == false
      assert LimitKeys.default_for(:search_semantic_enabled, :free) == false
      assert LimitKeys.default_for(:indexed_notes_cap, :free) == 2_000
      assert LimitKeys.default_for(:api_write_enabled, :free) == false
      assert LimitKeys.default_for(:api_rps_cap, :free) == 0
      assert LimitKeys.default_for(:inactivity_warnings_exempt, :free) == false
      assert LimitKeys.default_for(:inactivity_delete_days, :free) == 90
    end

    test "starter tier matrix matches spec §9.2" do
      assert LimitKeys.default_for(:notes_cap, :starter) == 50_000
      assert LimitKeys.default_for(:vaults_cap, :starter) == 5
      assert LimitKeys.default_for(:attachment_bytes_cap, :starter) == 3_221_225_472
      assert LimitKeys.default_for(:max_file_bytes, :starter) == 209_715_200
      assert LimitKeys.default_for(:lifetime_embed_token_cap, :starter) == nil
      assert LimitKeys.default_for(:ai_queries_per_day, :starter) == 500
      assert LimitKeys.default_for(:search_semantic_enabled, :starter) == true
      assert LimitKeys.default_for(:indexed_notes_cap, :starter) == nil
      # API keys are Pro-only. Starter keeps MCP + vault sync + web app,
      # which authenticate without an API key and so bypass both gates.
      assert LimitKeys.default_for(:api_write_enabled, :starter) == false
      assert LimitKeys.default_for(:api_rps_cap, :starter) == 0
    end

    test "pro tier matrix matches spec §9.2" do
      assert LimitKeys.default_for(:notes_cap, :pro) == nil
      assert LimitKeys.default_for(:vaults_cap, :pro) == 15
      assert LimitKeys.default_for(:attachment_bytes_cap, :pro) == 16_106_127_360
      assert LimitKeys.default_for(:max_file_bytes, :pro) == 524_288_000
      assert LimitKeys.default_for(:reranker_enabled, :pro) == true
      assert LimitKeys.default_for(:ai_queries_per_day, :pro) == 10_000
      assert LimitKeys.default_for(:search_semantic_enabled, :pro) == true
      assert LimitKeys.default_for(:indexed_notes_cap, :pro) == nil
      assert LimitKeys.default_for(:api_write_enabled, :pro) == true
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
    test "emits 96 tuples (32 keys × 3 tiers)" do
      tuples = LimitKeys.env_var_names()
      assert length(tuples) == 96
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
    test "obsidian_connections_cap is 2 on free, nil on paid" do
      assert LimitKeys.defined?(:obsidian_connections_cap)
      assert LimitKeys.default_for(:obsidian_connections_cap, :free) == 2
      assert LimitKeys.default_for(:obsidian_connections_cap, :starter) == nil
      assert LimitKeys.default_for(:obsidian_connections_cap, :pro) == nil
    end

    # Both keys gate the same count at two endpoints (EnforceDeviceCap on the
    # device-flow authorize, EnforceConnectionCap on OAuth consent). Raising
    # one alone leaves the other path rejecting at the old number, which reads
    # to the user as "the device limit is a lie".
    test "obsidian_connections_cap tracks concurrent_devices on every tier" do
      for tier <- LimitKeys.tiers() do
        assert LimitKeys.default_for(:obsidian_connections_cap, tier) ==
                 LimitKeys.default_for(:concurrent_devices, tier),
               "obsidian_connections_cap and concurrent_devices disagree on #{tier}"
      end
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
    assert LimitKeys.default_for(:attachments_enabled, :free) == true
    assert LimitKeys.default_for(:attachments_enabled, :starter) == true
    assert LimitKeys.default_for(:attachments_enabled, :pro) == true
  end

  test "attachments_all_types grants every tier the non-text MIME surface" do
    assert LimitKeys.defined?(:attachments_all_types)
    assert LimitKeys.type(:attachments_all_types) == :boolean
    assert LimitKeys.default_for(:attachments_all_types, :free) == true
    assert LimitKeys.default_for(:attachments_all_types, :starter) == true
    assert LimitKeys.default_for(:attachments_all_types, :pro) == true
  end

  test "the inverted attachments_text_only key is gone" do
    # It was the only boolean whose `true` meant "denied". `capabilities/1`
    # maps `:unlimited` (enforcement off) to `true` for every boolean, so that
    # one key inverted the meaning of disabling enforcement and cost every
    # self-hoster their images and PDFs.
    refute LimitKeys.defined?(:attachments_text_only)
  end

  test "every boolean limit is grant-shaped: enforcement-off must never restrict" do
    # The invariant that makes the whole class impossible. `:unlimited` maps to
    # `true` for booleans, so a key may only use `true` to mean "the user gets
    # the thing". A future key defaulting Free to `true` while Pro gets `false`
    # is inverted by construction and fails here.
    for key <- LimitKeys.all(), LimitKeys.type(key) == :boolean do
      free = LimitKeys.default_for(key, :free)
      pro = LimitKeys.default_for(key, :pro)

      refute free == true and pro == false,
             "#{key} is inverted (free=true, pro=false): `true` must mean granted"
    end
  end

  test "search dial keys are defined with correct types" do
    alias Engram.Billing.LimitKeys
    assert LimitKeys.defined?(:search_full_precision)
    assert LimitKeys.type(:search_full_precision) == :boolean
    assert LimitKeys.type(:search_diversity) == :integer
    assert LimitKeys.type(:search_candidate_pool) == :integer
    assert LimitKeys.type(:search_query_model) == :string
  end

  test "search dial defaults match the spec" do
    alias Engram.Billing.LimitKeys
    assert LimitKeys.default_for(:search_diversity, :free) == 30
    assert LimitKeys.default_for(:search_diversity, :pro) == 30
    assert LimitKeys.default_for(:search_candidate_pool, :free) == 20
    assert LimitKeys.default_for(:search_candidate_pool, :pro) == 30
    assert LimitKeys.default_for(:search_full_precision, :pro) == false
    assert LimitKeys.default_for(:search_query_model, :pro) == nil
  end
end
