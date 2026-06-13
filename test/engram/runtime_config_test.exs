defmodule Engram.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias Engram.RuntimeConfig

  defp getenv(map), do: fn key -> Map.get(map, key) end

  describe "rate_limit_auth_override/1" do
    test "applies the override only when CI=true" do
      env = getenv(%{"RATE_LIMIT_AUTH_OVERRIDE" => "1000", "CI" => "true"})
      assert RuntimeConfig.rate_limit_auth_override(env) == {:ok, 1000}
    end

    test "ignores the override when CI is not true (e.g. a stray prod env var)" do
      env = getenv(%{"RATE_LIMIT_AUTH_OVERRIDE" => "1000"})
      assert RuntimeConfig.rate_limit_auth_override(env) == {:ignored, "1000"}
    end

    test "ignores the override when CI is set to something other than true" do
      env = getenv(%{"RATE_LIMIT_AUTH_OVERRIDE" => "1000", "CI" => "false"})
      assert RuntimeConfig.rate_limit_auth_override(env) == {:ignored, "1000"}
    end

    test "returns :none when the override is absent" do
      assert RuntimeConfig.rate_limit_auth_override(getenv(%{"CI" => "true"})) == :none
    end

    test "returns :none when the override is blank" do
      env = getenv(%{"RATE_LIMIT_AUTH_OVERRIDE" => "", "CI" => "true"})
      assert RuntimeConfig.rate_limit_auth_override(env) == :none
    end
  end

  describe "pre_auth_rate_limit_override/1" do
    test "applies the override only when CI=true" do
      env = getenv(%{"PRE_AUTH_RATE_LIMIT_OVERRIDE" => "100000", "CI" => "true"})
      assert RuntimeConfig.pre_auth_rate_limit_override(env) == {:ok, 100_000}
    end

    test "ignores the override when CI is not true (e.g. a stray prod env var)" do
      env = getenv(%{"PRE_AUTH_RATE_LIMIT_OVERRIDE" => "100000"})
      assert RuntimeConfig.pre_auth_rate_limit_override(env) == {:ignored, "100000"}
    end

    test "ignores the override when CI is set to something other than true" do
      env = getenv(%{"PRE_AUTH_RATE_LIMIT_OVERRIDE" => "100000", "CI" => "false"})
      assert RuntimeConfig.pre_auth_rate_limit_override(env) == {:ignored, "100000"}
    end

    test "returns :none when the override is absent" do
      assert RuntimeConfig.pre_auth_rate_limit_override(getenv(%{"CI" => "true"})) == :none
    end

    test "returns :none when the override is blank" do
      env = getenv(%{"PRE_AUTH_RATE_LIMIT_OVERRIDE" => "", "CI" => "true"})
      assert RuntimeConfig.pre_auth_rate_limit_override(env) == :none
    end

    test "is independent of the auth override env var" do
      env = getenv(%{"RATE_LIMIT_AUTH_OVERRIDE" => "1000", "CI" => "true"})
      assert RuntimeConfig.pre_auth_rate_limit_override(env) == :none
    end
  end

  describe "validate_saas_origins!/3" do
    test "raises when a Clerk (saas) deploy has no PHX_HOST and is not CI" do
      assert_raise RuntimeError, ~r/PHX_HOST/, fn ->
        RuntimeConfig.validate_saas_origins!(:clerk, nil, false)
      end
    end

    test "does NOT raise in CI (the e2e-clerk stack runs Clerk auth on localhost without PHX_HOST)" do
      assert RuntimeConfig.validate_saas_origins!(:clerk, nil, true) == :ok
    end

    test "passes for a Clerk deploy with PHX_HOST set" do
      assert RuntimeConfig.validate_saas_origins!(
               :clerk,
               %{origins: ["https://app.engram.page"]},
               false
             ) == :ok
    end

    test "passes for self-host (local auth) without PHX_HOST — same-origin is fine" do
      assert RuntimeConfig.validate_saas_origins!(:local, nil, false) == :ok
    end
  end

  describe "database_ssl/2" do
    test "returns [] when DATABASE_SSL is off (self-host / local pg)" do
      assert RuntimeConfig.database_ssl(getenv(%{}), "db.local") == []
      assert RuntimeConfig.database_ssl(getenv(%{"DATABASE_SSL" => "false"}), "db.local") == []
    end

    test "defaults to verify_none when SSL is on but no mode set (unchanged prod behavior)" do
      env = getenv(%{"DATABASE_SSL" => "true"})
      assert [ssl: opts] = RuntimeConfig.database_ssl(env, "db.rds.amazonaws.com")
      assert opts[:verify] == :verify_none
      refute Keyword.has_key?(opts, :cacerts)
    end

    test "verify-full enables peer verification with the OS trust store + SNI + hostname check" do
      env = getenv(%{"DATABASE_SSL" => "true", "DATABASE_SSL_MODE" => "verify-full"})
      assert [ssl: opts] = RuntimeConfig.database_ssl(env, "db.rds.amazonaws.com")
      assert opts[:verify] == :verify_peer
      assert opts[:server_name_indication] == ~c"db.rds.amazonaws.com"
      assert Keyword.has_key?(opts, :cacerts)
      assert Keyword.has_key?(opts, :customize_hostname_check)
    end

    test "verify-full is ignored when SSL itself is off (must opt into TLS first)" do
      env = getenv(%{"DATABASE_SSL_MODE" => "verify-full"})
      assert RuntimeConfig.database_ssl(env, "db.rds.amazonaws.com") == []
    end
  end
end
