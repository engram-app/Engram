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

  test "completing with a non-final part under the S3 minimum is entity_too_small" do
    key = "in-memory-test/#{System.unique_integer([:positive])}"
    {:ok, id} = InMemory.start_multipart(key)
    {:ok, e1} = InMemory.upload_part(key, id, 1, "x")
    {:ok, e2} = InMemory.upload_part(key, id, 2, "y")

    assert {:error, :entity_too_small} =
             InMemory.complete_multipart_upload(key, id, [
               %{part_number: 1, etag: e1},
               %{part_number: 2, etag: e2}
             ])
  end

  test "a single small (final) part is fine" do
    key = "in-memory-test/#{System.unique_integer([:positive])}"
    {:ok, id} = InMemory.start_multipart(key)
    {:ok, e1} = InMemory.upload_part(key, id, 1, "x")
    assert :ok = InMemory.complete_multipart_upload(key, id, [%{part_number: 1, etag: e1}])
  end
end
