defmodule Engram.Crypto.PathCrypto do
  @moduledoc """
  AAD-bound path decryption, shared by every controller that renders
  cleartext paths from `path_ciphertext`.

  Extracted from SyncController so the manifest and the vault-tree read
  cannot drift on AAD binding: rows with `dek_version >= 2` bind to
  "notes:path:<id>" / "attachments:path:<id>", and legacy v1 rows decrypt
  with empty AAD. Getting that wrong on one caller and not the other is a
  silent decrypt failure at best.
  """

  alias Engram.Crypto
  alias Engram.Crypto.Envelope

  @spec aad(atom(), binary(), integer() | nil) :: binary()
  def aad(table, id, dek_version) when is_integer(dek_version) and dek_version >= 2,
    do: Crypto.aad_for_row(table, :path, id)

  def aad(_table, _id, _v), do: <<>>

  @doc """
  Batch `decrypt!/4` over `[{raw_id, dek_version, ct, nonce}]`, same AAD
  rule as `aad/3`, one native call. Raises like `decrypt!/4`.
  """
  @spec decrypt_many!(atom(), [{<<_::128>>, integer() | nil, binary(), binary()}], <<_::256>>) ::
          [binary()]
  def decrypt_many!(table, rows, dek) do
    bound = Crypto.row_version_aad_bound()

    fields =
      Enum.map(rows, fn {raw_id, v, ct, nonce} ->
        {raw_id, is_integer(v) and v >= bound, ct, nonce}
      end)

    case Envelope.decrypt_many(dek, Crypto.aad_prefix(table, :path), fields) do
      {:ok, paths} -> paths
      :error -> raise "path decrypt failed — possible data corruption"
    end
  end

  @spec decrypt!(binary(), binary(), <<_::256>>, binary()) :: binary()
  def decrypt!(ciphertext, nonce, dek, aad) do
    case Envelope.decrypt(ciphertext, nonce, dek, aad) do
      {:ok, path} -> path
      :error -> raise "path decrypt failed — possible data corruption"
    end
  end
end
