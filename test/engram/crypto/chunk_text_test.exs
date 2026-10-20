defmodule Engram.Crypto.ChunkTextTest do
  # Chunk text and heading live encrypted on the `chunks` row (Task 11.1),
  # bound to the point id, so search reads them from Postgres, not Qdrant.
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

  test "text and heading are bound to their own column" do
    id = Ecto.UUID.generate()
    row = Crypto.encrypt_chunk_text("t", "h", @dek, id)

    swapped = %{
      row
      | text_ciphertext: row.heading_ciphertext,
        text_nonce: row.heading_nonce
    }

    assert :error = Crypto.decrypt_chunk_text(swapped, @dek, id)
  end

  test "another user's DEK fails" do
    id = Ecto.UUID.generate()
    row = Crypto.encrypt_chunk_text("t", "h", @dek, id)

    assert :error = Crypto.decrypt_chunk_text(row, :crypto.strong_rand_bytes(32), id)
  end

  test "a row with no ciphertext reads as :none (written before the column)" do
    id = Ecto.UUID.generate()
    blank = %{text_ciphertext: nil, text_nonce: nil, heading_ciphertext: nil, heading_nonce: nil}

    assert :none = Crypto.decrypt_chunk_text(blank, @dek, id)
  end

  test "chunk text and heading are on the zstd policy" do
    id = Ecto.UUID.generate()

    assert Envelope.compression_policy(Crypto.aad_for_row(:chunks, :text, id)) == :zstd
    assert Envelope.compression_policy(Crypto.aad_for_row(:chunks, :heading, id)) == :zstd
  end
end
