defmodule Engram.Crypto.ChunkTextTest do
  # A big note's chunk text and heading live on the `chunks` row as ONE
  # envelope, `display_ct` (Task 11.1, hybrid), bound to the point id.
  use ExUnit.Case, async: true

  alias Engram.Crypto
  alias Engram.Crypto.Envelope

  @dek :crypto.strong_rand_bytes(32)

  test "text and a string heading round trip" do
    id = Ecto.UUID.generate()
    row = Crypto.encrypt_chunk_text("Ferritin was low.", "Labs > Iron", @dek, id)

    assert {:ok, {"Ferritin was low.", "Labs > Iron"}} = Crypto.decrypt_chunk_text(row, @dek, id)
  end

  test "a heading list survives exactly" do
    id = Ecto.UUID.generate()
    row = Crypto.encrypt_chunk_text("body", ["X", "A > B"], @dek, id)

    assert {:ok, {"body", ["X", "A > B"]}} = Crypto.decrypt_chunk_text(row, @dek, id)
  end

  test "a nil heading and empty text round trip" do
    id = Ecto.UUID.generate()
    row = Crypto.encrypt_chunk_text("", nil, @dek, id)

    assert {:ok, {"", nil}} = Crypto.decrypt_chunk_text(row, @dek, id)
  end

  test "the ciphertext is bound to its point id: a swapped row fails" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    row_a = Crypto.encrypt_chunk_text("secret a", "H", @dek, a)

    assert :error = Crypto.decrypt_chunk_text(row_a, @dek, b)
  end

  test "one envelope per row: a single display_ct column" do
    row = Crypto.encrypt_chunk_text("t", "h", @dek, Ecto.UUID.generate())
    assert Map.keys(row) == [:display_ct]
  end

  test "a truncated envelope is an error, not a crash" do
    id = Ecto.UUID.generate()
    %{display_ct: ct} = Crypto.encrypt_chunk_text("t", "h", @dek, id)

    assert :error = Crypto.decrypt_chunk_text(%{display_ct: binary_part(ct, 0, 5)}, @dek, id)
    assert :error = Crypto.decrypt_chunk_text(%{display_ct: <<>>}, @dek, id)
  end

  test "another user's DEK fails" do
    id = Ecto.UUID.generate()
    row = Crypto.encrypt_chunk_text("t", "h", @dek, id)

    assert :error = Crypto.decrypt_chunk_text(row, :crypto.strong_rand_bytes(32), id)
  end

  test "a row with no ciphertext reads as :none (written before the column)" do
    id = Ecto.UUID.generate()
    blank = %{display_ct: nil}

    assert :none = Crypto.decrypt_chunk_text(blank, @dek, id)
  end

  test "the display envelope is on the zstd policy" do
    id = Ecto.UUID.generate()
    assert Envelope.compression_policy(Crypto.aad_for_row(:chunks, :display, id)) == :zstd
  end
end
