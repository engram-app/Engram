defmodule Engram.RebuildRuntimeConfigTest do
  # The v5 rebuild's tuning knobs, read from env at boot (INFRA-5 sets them on
  # the web and worker task defs). Unset must leave every key unconfigured,
  # so the code's default (today's behaviour) applies exactly.
  use ExUnit.Case, async: false

  @vars %{
    "QDRANT_DELETED_THRESHOLD" => :qdrant_deleted_threshold,
    "BM25_B_MERGED" => :bm25_b_merged,
    "TENANT_IDF_MIN_POINTS" => :tenant_idf_min_points,
    "LEGACY_FILTER_FIELDS" => :legacy_filter_fields,
    "REBUILD_LAST_USERS" => :rebuild_last_users
  }

  # The v5 switches whose prod value is now the code's only behaviour. A task
  # def still setting one (engram-infra drops them after this ships) must
  # boot, whatever the value.
  @retired %{
    "WRITE_V5_LAYOUT" => :write_v5_layout,
    "V5_PAYLOAD_FORMAT" => :v5_payload_format,
    "CHUNK_TEXT_WRITE" => :chunk_text_write,
    "CHUNK_TEXT_READ" => :chunk_text_read,
    "QDRANT_TENANT_GRAPH" => :qdrant_tenant_graph,
    "NOTE_POINTS_CAP_ENABLED" => :note_points_cap_enabled,
    "VECTOR_CACHE_ENABLED" => :vector_cache_enabled,
    "EMBED_MODELS_PER_PLAN" => :embed_models_per_plan
  }

  setup do
    vars = Map.keys(@vars) ++ Map.keys(@retired)
    previous = Map.new(vars, &{&1, System.get_env(&1)})
    Enum.each(vars, &System.delete_env/1)

    on_exit(fn ->
      for {var, value} <- previous,
          do: if(value, do: System.put_env(var, value), else: System.delete_env(var))
    end)
  end

  defp read_runtime, do: Config.Reader.read!("config/runtime.exs", env: :test, target: :host)
  defp engram(key), do: get_in(read_runtime(), [:engram, key])

  defp with_env(var, value) do
    System.put_env(var, value)
    engram(Map.fetch!(@vars, var))
  end

  test "unset leaves every key to the code default" do
    for {_var, key} <- @vars, do: assert(engram(key) == nil, "#{key} configured while unset")
  end

  for var <- ["QDRANT_DELETED_THRESHOLD", "BM25_B_MERGED"] do
    test "#{var} is a fraction from 0 to 1" do
      assert with_env(unquote(var), "0.35") == 0.35
      assert with_env(unquote(var), "1") == 1.0
      assert with_env(unquote(var), "0") == 0.0
    end

    test "#{var} out of range or not a number refuses to boot" do
      for bad <- ["1.5", "-0.1", "abc", "0.2x", ""] do
        System.put_env(unquote(var), bad)
        assert_raise RuntimeError, ~r/#{unquote(var)}/, &read_runtime/0
      end
    end
  end

  test "TENANT_IDF_MIN_POINTS is a non-negative integer" do
    assert with_env("TENANT_IDF_MIN_POINTS", "2500") == 2500
    assert with_env("TENANT_IDF_MIN_POINTS", "0") == 0

    for bad <- ["-1", "1.5", "lots"] do
      System.put_env("TENANT_IDF_MIN_POINTS", bad)
      assert_raise RuntimeError, ~r/TENANT_IDF_MIN_POINTS/, &read_runtime/0
    end
  end

  # On its own: every new point is written in the v5 layout now, so turning
  # legacy filters off no longer needs WRITE_V5_LAYOUT next to it.
  test "LEGACY_FILTER_FIELDS is a switch" do
    assert with_env("LEGACY_FILTER_FIELDS", "false") == false
    assert with_env("LEGACY_FILTER_FIELDS", "true") == true
    System.put_env("LEGACY_FILTER_FIELDS", "maybe")
    assert_raise RuntimeError, ~r/LEGACY_FILTER_FIELDS must be true or false/, &read_runtime/0
  end

  test "REBUILD_LAST_USERS is a comma-separated list of user ids" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    assert with_env("REBUILD_LAST_USERS", " #{a}, #{String.upcase(b)} ,") == [a, b]
    assert with_env("REBUILD_LAST_USERS", "") == []

    System.put_env("REBUILD_LAST_USERS", "#{a},not-a-uuid")
    assert_raise RuntimeError, ~r/REBUILD_LAST_USERS/, &read_runtime/0
  end

  test "a retired v5 switch configures nothing and never refuses to boot" do
    for {var, _key} <- @retired, do: System.put_env(var, "yes")
    System.put_env("LEGACY_FILTER_FIELDS", "true")
    config = read_runtime()

    for {_var, key} <- @retired,
        do: assert(get_in(config, [:engram, key]) == nil, "#{key} configured")
  end
end
