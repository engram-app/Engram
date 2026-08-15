defmodule Engram.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias Engram.RuntimeConfig

  defp getenv(map), do: fn key -> Map.get(map, key) end

  describe "rate_limit_overrides/0" do
    # Pins the exact env var names + application env keys. A typo in either half
    # is a silent regression: the CI stack stops being able to loosen a limiter,
    # or (worse) a limiter reads a key nothing ever sets.
    test "lists every CI-overridable limiter" do
      assert RuntimeConfig.rate_limit_overrides() == [
               {"RATE_LIMIT_AUTH_OVERRIDE", :rate_limit_auth_override},
               {"PRE_AUTH_RATE_LIMIT_OVERRIDE", :pre_auth_rate_limit_override},
               {"CRDT_MSG_RATE_LIMIT_OVERRIDE", :crdt_msg_rate_limit_override},
               {"CRDT_HS_RATE_LIMIT_OVERRIDE", :crdt_hs_rate_limit_override}
             ]
    end
  end

  describe "drain_overrides/0" do
    # Pins the env var names and the NESTED config targets. These turn the #1152
    # room drain ON in a CI stack — the only place it ever runs against a real
    # client — so a typo silently reverts the e2e suite to never exercising it.
    test "lists the CRDT room-drain levers with their module + key targets" do
      assert RuntimeConfig.drain_overrides() == [
               {"CRDT_IDLE_EXIT_MS", {Engram.Notes.CrdtCheckpointTimer, :idle_exit_ms}},
               {"CRDT_MAX_RESIDENT_ROOMS", {Engram.Notes.CrdtRoomLru, :max_resident}}
             ]
    end

    # The gate matters more here than for a rate limiter: a stray
    # CRDT_IDLE_EXIT_MS reaching production would start draining rooms on a
    # timer in a deployment that has never exercised that path.
    for {var, _target} <- RuntimeConfig.drain_overrides() do
      test "#{var} is ignored outside CI" do
        assert RuntimeConfig.ci_gated_int_override(
                 getenv(%{unquote(var) => "5000"}),
                 unquote(var)
               ) ==
                 {:ignored, "5000"}
      end

      test "#{var} applies when CI=true" do
        env = getenv(%{unquote(var) => "5000", "CI" => "true"})
        assert RuntimeConfig.ci_gated_int_override(env, unquote(var)) == {:ok, 5000}
      end
    end
  end

  describe "ci_gated_int_override/2" do
    # Run the full gating contract against every override so no limiter can
    # drift onto a different rule.
    for {var, _key} <- RuntimeConfig.rate_limit_overrides() do
      test "#{var} applies only when CI=true" do
        env = getenv(%{unquote(var) => "100000", "CI" => "true"})
        assert RuntimeConfig.ci_gated_int_override(env, unquote(var)) == {:ok, 100_000}
      end

      test "#{var} is ignored when CI is unset (e.g. a stray prod env var)" do
        env = getenv(%{unquote(var) => "100000"})
        assert RuntimeConfig.ci_gated_int_override(env, unquote(var)) == {:ignored, "100000"}
      end

      test "#{var} is ignored when CI is set to something other than true" do
        env = getenv(%{unquote(var) => "100000", "CI" => "false"})
        assert RuntimeConfig.ci_gated_int_override(env, unquote(var)) == {:ignored, "100000"}
      end

      test "#{var} returns :none when absent" do
        assert RuntimeConfig.ci_gated_int_override(getenv(%{"CI" => "true"}), unquote(var)) ==
                 :none
      end

      test "#{var} returns :none when blank" do
        env = getenv(%{unquote(var) => "", "CI" => "true"})
        assert RuntimeConfig.ci_gated_int_override(env, unquote(var)) == :none
      end
    end

    test "each override reads only its own env var" do
      env = getenv(%{"RATE_LIMIT_AUTH_OVERRIDE" => "1000", "CI" => "true"})

      assert RuntimeConfig.ci_gated_int_override(env, "RATE_LIMIT_AUTH_OVERRIDE") == {:ok, 1000}
      assert RuntimeConfig.ci_gated_int_override(env, "PRE_AUTH_RATE_LIMIT_OVERRIDE") == :none
      assert RuntimeConfig.ci_gated_int_override(env, "CRDT_MSG_RATE_LIMIT_OVERRIDE") == :none
      assert RuntimeConfig.ci_gated_int_override(env, "CRDT_HS_RATE_LIMIT_OVERRIDE") == :none
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
