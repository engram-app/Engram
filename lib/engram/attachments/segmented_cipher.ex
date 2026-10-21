defmodule Engram.Attachments.SegmentedCipher do
  @moduledoc """
  Attachment content format v2: a random per-file key seals the content as
  independent segments (one per upload part), and the user's DEK wraps only
  that key. Uploads can resume part by part, downloads can stream, and DEK
  rotation rewraps 32 bytes instead of re-encrypting the object.

  A sealed segment is `nonce(12) || ciphertext || tag(16)`, exactly
  `overhead/0` bytes larger than its plaintext: the segment AAD prefix is not
  in `Envelope`'s compression policy, so segments are always format 0.

  Segment AAD: `aad_prefix(:attachments, :segment) <> upload_id(16 raw bytes)
  <> <<index::32, count::32, final::8>>`, `final` = `index == count - 1`.
  Binding all four rejects reordered segments, segments swapped in from
  another upload, and a stream truncated at a non-final segment.

  The wrapped file key's AAD is `Crypto.aad_for_row(:attachments, :file_key, att_id)`.
  """

  alias Engram.Crypto
  alias Engram.Crypto.Envelope

  @nonce_bytes 12
  @segment_prefix Crypto.aad_prefix(:attachments, :segment)

  @spec new_file_key() :: <<_::256>>
  def new_file_key, do: :crypto.strong_rand_bytes(32)

  @doc "Bytes a sealed segment adds to its plaintext."
  # No @spec: literal body (same reason as Envelope.tag_bytes/0).
  def overhead, do: @nonce_bytes + Envelope.tag_bytes()

  @spec wrap_key(<<_::256>>, <<_::256>>, Ecto.UUID.t()) :: {binary(), binary()}
  def wrap_key(<<_::256>> = file_key, dek, att_id),
    do: Envelope.encrypt(file_key, dek, key_aad(att_id))

  @spec unwrap_key(binary(), binary(), <<_::256>>, Ecto.UUID.t()) :: {:ok, <<_::256>>} | :error
  def unwrap_key(wrapped, nonce, dek, att_id) do
    case Envelope.decrypt(wrapped, nonce, dek, key_aad(att_id)) do
      {:ok, <<_::256>> = file_key} -> {:ok, file_key}
      _ -> :error
    end
  end

  @spec seal_segment(binary(), <<_::256>>, Ecto.UUID.t(), non_neg_integer(), pos_integer()) ::
          binary()
  def seal_segment(plaintext, <<_::256>> = file_key, upload_id, index, count)
      when is_integer(index) and is_integer(count) and index >= 0 and index < count do
    {ct, <<_::binary-size(@nonce_bytes)>> = nonce} =
      Envelope.encrypt(plaintext, file_key, segment_aad(upload_id, index, count))

    nonce <> ct
  end

  @spec open_segment(binary(), <<_::256>>, Ecto.UUID.t(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | :error
  def open_segment(
        <<nonce::binary-size(@nonce_bytes), ct::binary>>,
        <<_::256>> = file_key,
        upload_id,
        index,
        count
      )
      when is_integer(index) and is_integer(count) and index >= 0 and index < count and
             byte_size(ct) >= 16,
      do: Envelope.decrypt(ct, nonce, file_key, segment_aad(upload_id, index, count))

  def open_segment(_sealed, _file_key, _upload_id, _index, _count), do: :error

  defp key_aad(att_id), do: Crypto.aad_for_row(:attachments, :file_key, att_id)

  defp segment_aad(upload_id, index, count) do
    final = if index == count - 1, do: 1, else: 0
    {:ok, raw} = Ecto.UUID.dump(upload_id)
    @segment_prefix <> raw <> <<index::32, count::32, final::8>>
  end
end
