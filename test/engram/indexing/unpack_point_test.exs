defmodule Engram.Indexing.UnpackPointTest do
  use ExUnit.Case, async: true

  alias Engram.Indexing

  defp point do
    %{
      id: Ecto.UUID.generate(),
      vector: %{"dense" => Engram.Native.pack_f32([0.5, -1.0])},
      payload: %{"u" => Ecto.UUID.generate(), "p" => Ecto.UUID.generate()}
    }
  end

  test "the dense vector goes out as a JSON fragment, the payload unchanged" do
    p = point()
    unpacked = Indexing.unpack_point(p)

    assert %Jason.Fragment{} = unpacked.vector["dense"]
    assert Jason.decode!(Jason.encode!(unpacked.vector)) == %{"dense" => [0.5, -1.0]}
    assert unpacked.payload == p.payload
  end

  test "points without a payload (update_vectors) are left payload-free" do
    p = Map.delete(point(), :payload)
    refute Map.has_key?(Indexing.unpack_point(p), :payload)
  end
end
