defmodule Engram.Vector.FilterIdTest do
  use ExUnit.Case, async: true

  alias Engram.Crypto
  alias Engram.Vector.FilterId

  @uuid ~r/^[0-9a-f]{32}$/

  test "from_hmac formats the first 128 bits, pinned" do
    hmac = :crypto.mac(:hmac, :sha256, <<1::256>>, "projects/a.md")
    assert FilterId.from_hmac(hmac) == Base.encode16(binary_part(hmac, 0, 16), case: :lower)
    assert FilterId.from_hmac(<<0::128, 0xFF::128>>) == "00000000000000000000000000000000"
    assert FilterId.from_hmac(hmac) =~ @uuid
  end

  test "from_hmac of nil is nil" do
    assert FilterId.from_hmac(nil) == nil
  end

  test "uuid/1 strips the dashes of an Ecto UUID" do
    assert FilterId.uuid("6f9619ff-8b86-d011-b42d-00c04fc964ff") ==
             "6f9619ff8b86d011b42d00c04fc964ff"
  end

  test "keys and values live in different HMAC domains" do
    fk = :crypto.strong_rand_bytes(32)
    refute FilterId.attr(fk, "draft") == FilterId.attr_value(fk, "draft")
    refute Crypto.hmac_field(fk, "draft") == FilterId.value_hmac(fk, "draft")
  end

  test "values are case and width normalised" do
    fk = :crypto.strong_rand_bytes(32)
    assert FilterId.attr_value(fk, "Draft") == FilterId.attr_value(fk, "draft")
    assert FilterId.attr(fk, "Rating") == FilterId.attr(fk, "rating")
  end

  test "cross tenant: the same status under two users gives different ids" do
    a = :crypto.strong_rand_bytes(32)
    b = :crypto.strong_rand_bytes(32)
    refute FilterId.attr_value(a, "draft") == FilterId.attr_value(b, "draft")
    refute FilterId.attr(a, "status") == FilterId.attr(b, "status")
  end
end
