defmodule Engram.PromExRegistrationTest do
  @moduledoc """
  A PromEx plugin that emits telemetry but is not listed in `Engram.PromEx.plugins/0`
  compiles, passes its own tests, and silently never reaches the scraped
  `/metrics` endpoint. That is a bad failure mode for a counter whose whole job
  is proving a memory-control feature works in production, so pin the wiring.
  """
  use ExUnit.Case, async: true

  test "the CRDT room-drain plugin is actually registered" do
    registered =
      Enum.map(Engram.PromEx.plugins(), fn
        {mod, _opts} -> mod
        mod -> mod
      end)

    assert Engram.PromEx.Crdt in registered
  end
end
