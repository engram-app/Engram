defmodule Engram.Indexing.PointIdTest do
  use ExUnit.Case, async: true

  alias Engram.Indexing.PointId

  @note "8c1d7a42-3f0e-4b1a-9c55-0d2e6f7a8b90"

  test "v5 is a valid version-5 UUID, stable across calls" do
    id = PointId.v5(@note, <<1, 2, 3>>, 0)
    assert id == PointId.v5(@note, <<1, 2, 3>>, 0)
    assert {:ok, _} = Ecto.UUID.cast(id)
    assert String.at(id, 14) == "5"
    assert String.at(id, 19) in ~w(8 9 a b)
  end

  test "differs per ordinal, fingerprint and note" do
    base = PointId.v5(@note, <<1>>, 0)
    refute base == PointId.v5(@note, <<1>>, 1)
    refute base == PointId.v5(@note, <<2>>, 0)
    refute base == PointId.v5(Ecto.UUID.generate(), <<1>>, 0)
  end

  test "matches RFC 4122 v5 for a known name" do
    # Python: uuid.uuid5(uuid.NAMESPACE_DNS, "python.org")
    assert PointId.uuid5("6ba7b810-9dad-11d1-80b4-00c04fd430c8", "python.org") ==
             "886313e1-3b8a-5372-9b90-0c9aee199e5d"
  end

  test "ordinals count equal fingerprints in position order" do
    assert PointId.ordinals([<<1>>, <<2>>, <<1>>, nil, <<1>>]) == [0, 0, 1, 0, 2]
  end

  test "a chunk inserted above keeps the ids of chunks below" do
    before = Enum.zip([<<1>>, <<2>>], PointId.ordinals([<<1>>, <<2>>]))
    after_ = Enum.zip([<<9>>, <<1>>, <<2>>], PointId.ordinals([<<9>>, <<1>>, <<2>>]))
    ids = fn pairs -> for {fp, o} <- pairs, fp != <<9>>, do: PointId.v5(@note, fp, o) end
    assert ids.(before) == ids.(after_)
  end
end
