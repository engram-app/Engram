defmodule Engram.Indexing.RetainedVectorsTest do
  # async: false: the cache table is node-wide.
  use ExUnit.Case, async: false

  alias Engram.Indexing.RetainedVectors

  setup do
    Engram.Cache.clear_local(:retained_vectors)
    on_exit(fn -> Engram.Cache.clear_local(:retained_vectors) end)
  end

  # `n` packed 1024d f32 vectors: 4096 bytes each.
  defp vectors(n), do: List.duplicate(:binary.copy(<<0>>, 4096), n)
  defp key(note_id), do: {note_id, "embed-key"}

  test "inserting past the cap evicts oldest first and stays under the cap" do
    cap = 10 * 4096
    for id <- ~w(a b c), do: :ok = RetainedVectors.put(key(id), vectors(4), cap)

    # a + b + c = 12 vectors > 10, so the oldest (a) went when c arrived.
    assert RetainedVectors.get(key("a")) == :miss
    assert {:ok, _} = RetainedVectors.get(key("b"))
    assert {:ok, _} = RetainedVectors.get(key("c"))
    assert RetainedVectors.total_bytes() <= cap

    # b + c + d = 14 > 10: only the oldest (b) goes; c + d fits exactly.
    :ok = RetainedVectors.put(key("d"), vectors(6), cap)
    assert RetainedVectors.get(key("b")) == :miss
    assert {:ok, _} = RetainedVectors.get(key("c"))
    assert {:ok, _} = RetainedVectors.get(key("d"))
    assert RetainedVectors.total_bytes() == cap
  end

  test "a new put for the same note replaces its old entry" do
    :ok = RetainedVectors.put({"n", "old-key"}, vectors(2), 10 * 4096)
    :ok = RetainedVectors.put({"n", "new-key"}, vectors(3), 10 * 4096)

    assert RetainedVectors.get({"n", "old-key"}) == :miss
    assert {:ok, v} = RetainedVectors.get({"n", "new-key"})
    assert length(v) == 3
    assert RetainedVectors.total_bytes() == 3 * 4096
  end

  test "an entry larger than the whole cap is not held and evicts nothing" do
    :ok = RetainedVectors.put(key("small"), vectors(1), 4 * 4096)
    :ok = RetainedVectors.put(key("huge"), vectors(5), 4 * 4096)

    assert RetainedVectors.get(key("huge")) == :miss
    assert {:ok, _} = RetainedVectors.get(key("small"))
  end

  test "forget drops the note's entry" do
    :ok = RetainedVectors.put(key("f"), vectors(1), 4096)
    :ok = RetainedVectors.forget(key("f"))
    assert RetainedVectors.get(key("f")) == :miss
    assert RetainedVectors.total_bytes() == 0
  end
end
