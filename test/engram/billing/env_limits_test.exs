defmodule Engram.Billing.EnvLimitsTest do
  use ExUnit.Case, async: true

  alias Engram.Billing.EnvLimits

  describe "parse!/3 — :integer" do
    test "parses positive integer" do
      assert EnvLimits.parse!("10000", :integer, "ENGRAM_FREE_NOTES_CAP") == 10_000
    end

    test "parses zero" do
      assert EnvLimits.parse!("0", :integer, "ENGRAM_FREE_API_RPS_CAP") == 0
    end

    test "raises on non-numeric" do
      assert_raise ArgumentError, fn ->
        EnvLimits.parse!("not_a_number", :integer, "ENGRAM_FREE_NOTES_CAP")
      end
    end

    test "raises on empty string" do
      assert_raise ArgumentError, fn ->
        EnvLimits.parse!("", :integer, "ENGRAM_FREE_NOTES_CAP")
      end
    end
  end

  describe "parse!/3 — :boolean" do
    test "parses 'true'" do
      assert EnvLimits.parse!("true", :boolean, "ENGRAM_FREE_RERANKER_ENABLED") == true
    end

    test "parses 'false'" do
      assert EnvLimits.parse!("false", :boolean, "ENGRAM_FREE_RERANKER_ENABLED") == false
    end

    test "raises on 'yes' / '1' / other" do
      assert_raise RuntimeError, fn ->
        EnvLimits.parse!("1", :boolean, "ENGRAM_FREE_RERANKER_ENABLED")
      end

      assert_raise RuntimeError, fn ->
        EnvLimits.parse!("yes", :boolean, "ENGRAM_FREE_RERANKER_ENABLED")
      end
    end
  end

  describe "parse!/3 — error messages include env name" do
    test "integer error includes env name" do
      try do
        EnvLimits.parse!("oops", :integer, "ENGRAM_FREE_NOTES_CAP")
      rescue
        e -> assert Exception.message(e) =~ "ENGRAM_FREE_NOTES_CAP"
      end
    end

    test "boolean error includes env name" do
      try do
        EnvLimits.parse!("oops", :boolean, "ENGRAM_FREE_RERANKER_ENABLED")
      rescue
        e -> assert Exception.message(e) =~ "ENGRAM_FREE_RERANKER_ENABLED"
      end
    end
  end

  describe "parse!/3 — :string" do
    test "parse! accepts a string value for :string keys" do
      assert EnvLimits.parse!("voyage-4-large", :string, "ENV") == "voyage-4-large"
    end

    test "parse! rejects an empty string for :string keys" do
      assert_raise ArgumentError, fn ->
        EnvLimits.parse!("", :string, "ENGRAM_PRO_SEARCH_QUERY_MODEL")
      end
    end
  end
end
