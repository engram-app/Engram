defmodule Engram.Storage.InMemoryTest do
  use ExUnit.Case, async: true

  alias Engram.Storage.InMemory

  # An ETS table dies with its creator. If a test process creates the blob
  # table, its exit wipes every concurrent test's blobs; test_helper must own it.
  test "a blob outlives the process that stored it" do
    key = "in-memory-test/#{System.unique_integer([:positive])}"

    {pid, ref} = spawn_monitor(fn -> InMemory.put(key, "hi") end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert {:ok, "hi"} = InMemory.get(key)
  end
end
