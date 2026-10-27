defmodule Engram.QdrantRuntimeConfigTest do
  # Ops kill switches and backpressure knobs, read from env at boot in every
  # environment (prod and self-host), so a reconcile can be stopped with an
  # env change + restart rather than a code change.
  use ExUnit.Case, async: false

  @switches [
    {"QDRANT_RECONCILE_CONFIG", :qdrant_reconcile_config},
    {"QDRANT_RECONCILE_ON_DISK", :qdrant_reconcile_on_disk},
    {"QDRANT_STRICT_MODE", :qdrant_strict_mode},
    {"QDRANT_BACKPRESSURE_PREFLIGHT", :qdrant_backpressure_preflight}
  ]

  @integers [
    {"QDRANT_MEMORY_LIMIT_BYTES", :qdrant_memory_limit_bytes},
    {"QDRANT_MEMORY_RESERVE_BYTES", :qdrant_memory_reserve_bytes},
    {"QDRANT_STRICT_DISK_PERCENT", :qdrant_strict_disk_percent},
    {"QDRANT_STRICT_MEMORY_PERCENT", :qdrant_strict_memory_percent},
    {"QDRANT_PREFLIGHT_MARGIN_POINTS", :qdrant_preflight_margin_points}
  ]

  @cluster_vars ~w(QDRANT_ACTIVE_CLUSTER QDRANT_URL_V2 QDRANT_API_KEY_V2)

  setup do
    vars = Enum.map(@switches ++ @integers, &elem(&1, 0)) ++ @cluster_vars
    previous = Map.new(vars, &{&1, System.get_env(&1)})
    Enum.each(vars, &System.delete_env/1)

    on_exit(fn ->
      for {var, value} <- previous,
          do: if(value, do: System.put_env(var, value), else: System.delete_env(var))
    end)
  end

  defp read_runtime, do: Config.Reader.read!("config/runtime.exs", env: :test, target: :host)
  defp engram(key), do: get_in(read_runtime(), [:engram, key])

  for {var, key} <- @switches do
    test "#{var}=false turns #{key} off; true turns it on" do
      System.put_env(unquote(var), "false")
      assert engram(unquote(key)) == false
      System.put_env(unquote(var), "true")
      assert engram(unquote(key)) == true
    end

    test "#{var} unset leaves the default (on) in place" do
      assert engram(unquote(key)) == nil
    end

    test "#{var}=maybe refuses to boot" do
      System.put_env(unquote(var), "maybe")
      assert_raise RuntimeError, ~r/#{unquote(var)} must be true or false/, &read_runtime/0
    end
  end

  for {var, key} <- @integers do
    test "#{var} is read as an integer" do
      System.put_env(unquote(var), "42")
      assert engram(unquote(key)) == 42
    end
  end

  # The second-cluster slot is gone. Prod pins QDRANT_ACTIVE_CLUSTER=old until
  # engram-infra drops it; a stale `v2` (with no V2 vars) must boot too.
  describe "QDRANT_ACTIVE_CLUSTER (retired)" do
    import ExUnit.CaptureIO

    test "old boots silently and configures no cluster key" do
      System.put_env("QDRANT_ACTIVE_CLUSTER", "old")

      err =
        capture_io(:stderr, fn ->
          assert get_in(read_runtime(), [:engram, :qdrant_active_cluster]) == nil
        end)

      refute err =~ "QDRANT_ACTIVE_CLUSTER"
    end

    test "v2 with no V2 vars boots, configures nothing and warns" do
      System.put_env("QDRANT_ACTIVE_CLUSTER", "v2")

      err =
        capture_io(:stderr, fn ->
          config = read_runtime()

          for key <- [:qdrant_active_cluster, :qdrant_url_v2, :qdrant_api_key_v2],
              do: assert(get_in(config, [:engram, key]) == nil)
        end)

      assert err =~ "QDRANT_ACTIVE_CLUSTER=\"v2\" is retired"
    end

    test "V2 vars are ignored" do
      System.put_env("QDRANT_URL_V2", "http://v2:6333")
      System.put_env("QDRANT_API_KEY_V2", "k")
      assert engram(:qdrant_url_v2) == nil
      assert engram(:qdrant_api_key_v2) == nil
    end
  end
end
