defmodule Engram.RuntimeConfigWiringTest do
  # RuntimeConfigTest covers http_compression/1; this proves runtime.exs calls
  # it, so deleting the wiring fails a test. Mutates the OS env: not async.
  use ExUnit.Case, async: false

  setup do
    prev = System.get_env("ENGRAM_SAAS_ONLY")

    on_exit(fn ->
      if prev,
        do: System.put_env("ENGRAM_SAAS_ONLY", prev),
        else: System.delete_env("ENGRAM_SAAS_ONLY")
    end)
  end

  defp http_options do
    Config.Reader.read!("config/runtime.exs", env: :test, target: :host)
    |> get_in([:engram, EngramWeb.Endpoint, :http, :http_options])
  end

  test "runtime.exs turns origin compression off for a SaaS release" do
    System.put_env("ENGRAM_SAAS_ONLY", "true")
    assert http_options()[:compress] == false
  end

  test "runtime.exs leaves compression on for self-host" do
    System.delete_env("ENGRAM_SAAS_ONLY")
    assert http_options()[:compress] != false
  end
end
