defmodule Engram.Cache.FakeRedix do
  @moduledoc """
  In-memory stand-in for `Engram.Cache.Redix` used in tests. Implements the
  `command/1` contract the cache façade depends on (GET/SET) over an Agent map,
  so set→get round-trips without a live Redis. Inject via
  `config :engram, Engram.Cache, redis_impl: Engram.Cache.FakeRedix`.
  """
  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def command(["GET", key]), do: {:ok, Agent.get(__MODULE__, &Map.get(&1, key))}

  def command(["SET", key, value | _rest]) do
    Agent.update(__MODULE__, &Map.put(&1, key, value))
    {:ok, "OK"}
  end
end
