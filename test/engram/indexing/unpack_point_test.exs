defmodule Engram.Indexing.UnpackPointTest do
  use ExUnit.Case, async: true

  alias Engram.Indexing

  @b64_keys [:text, :text_nonce, :title, :title_nonce, :heading_path, :heading_path_nonce]

  defp b64(n), do: Base.encode64(:crypto.strong_rand_bytes(n))

  defp point do
    payload =
      Map.new(@b64_keys, &{&1, b64(40)})
      |> Map.merge(%{aad_version: 2, user_id: 1, vault_id: 2, path_hmac: b64(32), tags: [b64(8)]})

    %{
      id: Ecto.UUID.generate(),
      vector: %{"dense" => Engram.Native.pack_f32([0.5, -1.0])},
      payload: payload
    }
  end

  test "base64 payload fields are emitted as pre-encoded JSON fragments" do
    %{payload: payload} = Indexing.unpack_point(point())
    for k <- @b64_keys, do: assert(%Jason.Fragment{} = Map.fetch!(payload, k))
  end

  test "the encoded JSON is byte-identical to encoding the plain strings" do
    p = point()
    unpacked = Indexing.unpack_point(p)

    assert Jason.encode!(unpacked.payload) == Jason.encode!(p.payload)
    # Same check through Req's encoder entry point and with a "+/=" heavy value.
    p2 = put_in(p, [:payload, :text], "+/+/==")

    assert IO.iodata_to_binary(Jason.encode_to_iodata!(Indexing.unpack_point(p2).payload)) ==
             Jason.encode!(p2.payload)
  end

  test "an empty ciphertext field still encodes as an empty string" do
    p = put_in(point(), [:payload, :title], "")
    assert Jason.encode!(Indexing.unpack_point(p).payload) == Jason.encode!(p.payload)
  end

  test "points without a payload (update_vectors) are left payload-free" do
    p = Map.delete(point(), :payload)
    refute Map.has_key?(Indexing.unpack_point(p), :payload)
  end
end
