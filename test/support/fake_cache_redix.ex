defmodule Engram.Cache.FakeRedix do
  @moduledoc """
  In-memory stand-in for `Engram.Cache.Redix` used in tests. Implements the
  `command/1` contract the cache façade depends on (GET/SET) over an Agent so
  set→get round-trips without a live Redis. Inject via
  `config :engram, Engram.Cache, redis_impl: Engram.Cache.FakeRedix`.

  Records every command (see `commands/0`) so tests can assert the exact wire
  shape — key template and `EX <ttl>` — that the façade emits. `put_raw/2` seeds
  an arbitrary stored value to exercise corrupt/foreign-write decode paths.
  """
  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{store: %{}, commands: []} end, name: __MODULE__)
  end

  def command(["GET", key] = cmd) do
    Agent.update(__MODULE__, fn s -> %{s | commands: [cmd | s.commands]} end)
    {:ok, Agent.get(__MODULE__, fn s -> Map.get(s.store, key) end)}
  end

  def command(["SET", key, value | _rest] = cmd) do
    Agent.update(__MODULE__, fn s ->
      %{s | store: Map.put(s.store, key, value), commands: [cmd | s.commands]}
    end)

    {:ok, "OK"}
  end

  @doc "Commands seen so far, oldest first."
  def commands, do: __MODULE__ |> Agent.get(& &1.commands) |> Enum.reverse()

  @doc "Seed a raw stored value (bypasses the façade encoding)."
  def put_raw(key, value) do
    Agent.update(__MODULE__, fn s -> %{s | store: Map.put(s.store, key, value)} end)
  end
end
