defmodule Engram.Attachments.SegmentedCipherTest do
  use ExUnit.Case, async: true

  alias Engram.Attachments.SegmentedCipher
  alias Engram.Crypto.Envelope

  setup do
    %{key: SegmentedCipher.new_file_key(), upload_id: Ecto.UUID.generate()}
  end

  test "new_file_key/0 is 32 random bytes" do
    assert <<_::256>> = a = SegmentedCipher.new_file_key()
    refute a == SegmentedCipher.new_file_key()
  end

  describe "segments" do
    test "round-trips", %{key: key, upload_id: up} do
      sealed = SegmentedCipher.seal_segment("part one", key, up, 0, 2)
      assert {:ok, "part one"} = SegmentedCipher.open_segment(sealed, key, up, 0, 2)
    end

    test "round-trips an empty final segment", %{key: key, upload_id: up} do
      sealed = SegmentedCipher.seal_segment("", key, up, 0, 1)
      assert {:ok, ""} = SegmentedCipher.open_segment(sealed, key, up, 0, 1)
    end

    test "a different index, count, upload_id or key fails", %{key: key, upload_id: up} do
      sealed = SegmentedCipher.seal_segment("x", key, up, 1, 3)

      assert :error = SegmentedCipher.open_segment(sealed, key, up, 0, 3)
      assert :error = SegmentedCipher.open_segment(sealed, key, up, 1, 4)
      assert :error = SegmentedCipher.open_segment(sealed, key, Ecto.UUID.generate(), 1, 3)

      assert :error =
               SegmentedCipher.open_segment(sealed, SegmentedCipher.new_file_key(), up, 1, 3)
    end

    test "a non-final segment cannot be opened as the final one (truncation)", %{
      key: key,
      upload_id: up
    } do
      sealed = SegmentedCipher.seal_segment("middle", key, up, 1, 3)
      assert :error = SegmentedCipher.open_segment(sealed, key, up, 1, 2)
    end

    test "tampered or short input fails", %{key: key, upload_id: up} do
      <<head::binary-20, b, rest::binary>> = SegmentedCipher.seal_segment("abcdef", key, up, 0, 1)

      assert :error =
               SegmentedCipher.open_segment(head <> <<Bitwise.bxor(b, 1)>> <> rest, key, up, 0, 1)

      assert :error = SegmentedCipher.open_segment("short", key, up, 0, 1)
    end

    test "index must be below count", %{key: key, upload_id: up} do
      assert_raise FunctionClauseError, fn -> SegmentedCipher.seal_segment("x", key, up, 2, 2) end
      assert :error = SegmentedCipher.open_segment(<<0::size(8 * 40)>>, key, up, 2, 2)
    end

    test "never compressed: sealed size is exactly plaintext + nonce + tag", %{
      key: key,
      upload_id: up
    } do
      # Precondition: compression is on, so a compressible segment WOULD
      # shrink if the segment prefix were in Envelope's policy.
      assert Envelope.compression_on?()
      plaintext = :binary.copy(<<0>>, 1024 * 1024)
      sealed = SegmentedCipher.seal_segment(plaintext, key, up, 0, 1)
      assert byte_size(sealed) == byte_size(plaintext) + SegmentedCipher.overhead()
      assert SegmentedCipher.overhead() == 12 + Envelope.tag_bytes()
    end
  end

  describe "file key wrapping" do
    test "round-trips under the same att_id", %{key: key} do
      dek = :crypto.strong_rand_bytes(32)
      att_id = Ecto.UUID.generate()
      {wrapped, nonce} = SegmentedCipher.wrap_key(key, dek, att_id)
      refute wrapped =~ key
      assert {:ok, ^key} = SegmentedCipher.unwrap_key(wrapped, nonce, dek, att_id)
    end

    test "fails under a different att_id or dek", %{key: key} do
      dek = :crypto.strong_rand_bytes(32)
      att_id = Ecto.UUID.generate()
      {wrapped, nonce} = SegmentedCipher.wrap_key(key, dek, att_id)

      assert :error = SegmentedCipher.unwrap_key(wrapped, nonce, dek, Ecto.UUID.generate())

      assert :error =
               SegmentedCipher.unwrap_key(wrapped, nonce, :crypto.strong_rand_bytes(32), att_id)
    end
  end
end
