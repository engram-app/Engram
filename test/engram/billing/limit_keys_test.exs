defmodule Engram.Billing.LimitKeysTest do
  use ExUnit.Case, async: true

  alias Engram.Billing.LimitKeys

  describe "all/0" do
    test "returns the 28 catalog keys" do
      keys = LimitKeys.all()
      assert length(keys) == 28
      assert :notes_cap in keys
      assert :vaults_cap in keys
      assert :reranker_enabled in keys
      assert :cross_vault_search in keys
      assert :history_enabled in keys
      assert :mcp_tool_calls_per_min in keys
      assert :trash_retention_days in keys
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
    end

    test "raises FunctionClauseError on unknown key" do
      assert_raise FunctionClauseError, fn -> LimitKeys.type(:bogus) end
    end
  end

  describe "default_for/2 — full matrix pin" do
    test "free tier matrix matches spec §9.2" do
      # 3,000 since 2026-10-17: Free stores 3,000 notes and all of them are
      # searchable. The search-coverage cap was removed, not lowered. The
      # 2026-10-19 caps wait for the v5 go flag (see "v5 plan limits").
      assert LimitKeys.default_for(:notes_cap, :free) == 2_000
      assert LimitKeys.default_for(:vaults_cap, :free) == 1
      assert LimitKeys.default_for(:attachment_bytes_cap, :free) == 1_073_741_824
      assert LimitKeys.default_for(:max_file_bytes, :free) == 10_485_760
      assert LimitKeys.default_for(:embed_token_bucket, :free) == 6_000_000
      assert LimitKeys.default_for(:concurrent_devices, :free) == 2
      assert LimitKeys.default_for(:device_swap_cooldown_hours, :free) == 24
      # One AI meter, replacing six. See the note on the key in `LimitKeys`.
      assert LimitKeys.default_for(:ai_searches_per_day, :free) == 20
      assert LimitKeys.default_for(:ai_searches_per_day, :starter) == nil
      assert LimitKeys.default_for(:ai_searches_per_day, :pro) == nil
      assert LimitKeys.default_for(:reranker_enabled, :free) == false
      # Semantic search is every tier's; the key was removed, not flipped.
      refute :search_semantic_enabled in LimitKeys.all()
      refute LimitKeys.defined?(:indexed_notes_cap)
      # #1974: API keys work on every route on every tier; api_rps_cap is the
      # abuse bound, the same 30/s everywhere. There is no write flag.
      assert LimitKeys.default_for(:api_rps_cap, :free) == 30
      refute LimitKeys.defined?(:api_write_enabled)
      assert LimitKeys.default_for(:inactivity_warnings_exempt, :free) == false
      assert LimitKeys.default_for(:inactivity_delete_days, :free) == 90
      # Safer delete (#609): how long a deleted item stays restorable.
      assert LimitKeys.default_for(:trash_retention_days, :free) == 7
      assert LimitKeys.default_for(:trash_retention_days, :starter) == 30
      assert LimitKeys.default_for(:trash_retention_days, :pro) == 30
    end

    test "starter tier matrix matches spec §9.2" do
      assert LimitKeys.default_for(:notes_cap, :starter) == 20_000
      assert LimitKeys.default_for(:vaults_cap, :starter) == 10
      # 10 GiB. Raised from 3 GiB in pricing v3.1 (2026-09-03).
      assert LimitKeys.default_for(:attachment_bytes_cap, :starter) == 10_737_418_240
      assert LimitKeys.default_for(:max_file_bytes, :starter) == 209_715_200
      assert LimitKeys.default_for(:embed_token_bucket, :starter) == nil
      assert LimitKeys.default_for(:api_rps_cap, :starter) == 30
    end

    test "pro tier matrix matches spec §9.2" do
      assert LimitKeys.default_for(:notes_cap, :pro) == 40_000
      # Unlimited as of pricing v3.1 — vaults are packaging, not a resource.
      # Rooms are demand-started with `auto_exit`, index rooms are not
      # LRU-tracked, and every quota is per-user. See the decision log.
      assert LimitKeys.default_for(:vaults_cap, :pro) == nil
      # 50 GiB. Raised from 15 GiB in pricing v3.1 (2026-09-03).
      assert LimitKeys.default_for(:attachment_bytes_cap, :pro) == 53_687_091_200
      assert LimitKeys.default_for(:max_file_bytes, :pro) == 524_288_000
      assert LimitKeys.default_for(:reranker_enabled, :pro) == true
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
    test "emits one tuple per key per tier" do
      tuples = LimitKeys.env_var_names()
      # Derived, not a second hand-maintained literal: this count is a pure
      # function of the other two and two literals drift apart (the moduledoc
      # said 27 keys while the catalog held 33).
      assert length(tuples) == length(LimitKeys.all()) * length(LimitKeys.tiers())
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

    # #1974: MCP connections are uncapped on every tier; ai_searches_per_day
    # meters use. The key is gone, not defaulted to nil.
    test "there is no MCP connection cap" do
      refute LimitKeys.defined?(:mcp_connections_cap)
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

  test "the retired vault_scoped_keys entry is gone" do
    # Dead catalog entry: no gate, no client, superseded by the
    # `api_key_vaults` table. It reads like an obvious API-key feature, so
    # without this the only objection to re-adding it is an integer literal
    # that a re-adder bumps as a matter of course. If vault-scoping ever
    # returns as a plan limit, it needs a gate first — not a catalog row.
    refute LimitKeys.defined?(:vault_scoped_keys)
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

  test "index_points_cap bounds Qdrant points per account" do
    assert LimitKeys.defined?(:index_points_cap)
    assert LimitKeys.type(:index_points_cap) == :integer
    # notes_cap x 6: the v5 median is ~5.2 points a note (approved 10-19).
    assert LimitKeys.default_for(:index_points_cap, :free) == 12_000
    assert LimitKeys.default_for(:index_points_cap, :starter) == 120_000
    assert LimitKeys.default_for(:index_points_cap, :pro) == 240_000

    for tier <- [:free, :starter, :pro] do
      assert LimitKeys.default_for(:index_points_cap, tier) ==
               LimitKeys.default_for(:notes_cap, tier) * 6
    end
  end

  test "note_points_cap bounds dense points per note" do
    assert LimitKeys.defined?(:note_points_cap)
    assert LimitKeys.type(:note_points_cap) == :integer
    assert LimitKeys.default_for(:note_points_cap, :free) == 128
    assert LimitKeys.default_for(:note_points_cap, :starter) == 1_024
    assert LimitKeys.default_for(:note_points_cap, :pro) == 1_024
  end

  # Owner decisions 2026-10-19 and 2026-10-26: static defaults, no flag.
  test "notes_cap defaults are 2,000 / 20,000 / 40,000" do
    assert LimitKeys.default_for(:notes_cap, :free) == 2_000
    assert LimitKeys.default_for(:notes_cap, :starter) == 20_000
    assert LimitKeys.default_for(:notes_cap, :pro) == 40_000
  end
end
