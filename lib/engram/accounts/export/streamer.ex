defmodule Engram.Accounts.Export.Streamer do
  @moduledoc """
  Zips one vault per archive and streams it into an S3 multipart upload,
  returning the s3_keys list the `account_exports` row records.

  ## MVP scope (Task 12)

  Happy path only — one part per vault (`part: 1, of: 1`). The 10 GB part
  split, decryption of note/attachment bodies, and `.obsidian/`
  filtering are all stubbed pending Task 13/14. See the per-helper notes
  below for TODOs.

  Filenames inside the zip use `vault.slug` rather than the decrypted
  `vault.name` because note paths are encrypted (Phase B.3) and we don't
  yet hand the streamer a DEK; the same slug is also what appears in the
  s3 key so the user can correlate the download to the vault they
  recognise in the UI.
  """

  import Ecto.Query

  alias Engram.Accounts.Export.Schema
  alias Engram.Attachments.Attachment
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Storage
  alias Engram.Vaults.Vault

  # Minimum S3 part size for non-final parts (5 MiB). The streamer buffers
  # zip output until at least this much has accumulated, then flushes a
  # part. The final flush in `finalize_buffer/4` releases whatever's left
  # — S3 allows the last part to be < 5 MiB.
  @min_part_bytes 5 * 1024 * 1024

  @type part_map :: %{
          required(String.t()) => term()
        }

  @doc """
  Streams every non-deleted vault for `export.user_id` into S3, one zip
  per vault. Returns the s3_keys list (one map per part) and the total
  byte size across all parts.
  """
  @spec run(Schema.t(), keyword()) ::
          {:ok, [part_map()], non_neg_integer()} | {:error, term()}
  def run(%Schema{user_id: user_id} = export, _opts) do
    vaults =
      Repo.all(
        from(v in Vault,
          where: v.user_id == ^user_id and is_nil(v.deleted_at),
          order_by: [asc: v.id]
        ),
        skip_tenant_check: true
      )

    {parts, total} =
      Enum.reduce(vaults, {[], 0}, fn vault, {acc_parts, acc_bytes} ->
        {vault_parts, vault_bytes} = zip_vault(export, vault)
        {acc_parts ++ vault_parts, acc_bytes + vault_bytes}
      end)

    {:ok, parts, total}
  end

  # MVP: one part per vault. Task 14 will split at @part_max_bytes (10 GB).
  defp zip_vault(export, vault) do
    storage = Storage.adapter()
    key = part_key(export, vault, 1, 1)

    {:ok, upload_id} = storage.start_multipart(key)

    {total_bytes, finished_parts} =
      vault
      |> zip_entries()
      |> Zstream.zip()
      |> stream_to_multipart(storage, key, upload_id)

    :ok = storage.complete_multipart_upload(key, upload_id, finished_parts)

    part_map = %{
      "key" => key,
      "size_bytes" => total_bytes,
      "part" => 1,
      "of" => 1,
      "vault_id" => vault.id,
      "vault_name" => vault.slug
    }

    {[part_map], total_bytes}
  end

  # Build the zstream entry list for a vault. MVP: notes + attachments
  # are emitted as opaque ciphertext blobs because we don't have a DEK
  # in scope (Task 13 wires decryption). Filenames use the row id so the
  # zip remains deterministic and `.obsidian/`-filtering work in Task 14
  # has clean paths to match against once we decrypt.
  defp zip_entries(%Vault{id: vault_id}) do
    notes =
      Repo.all(
        from(n in Note,
          where:
            n.vault_id == ^vault_id and
              n.kind == "note" and
              is_nil(n.deleted_at),
          order_by: [asc: n.id]
        ),
        skip_tenant_check: true
      )

    attachments =
      Repo.all(
        from(a in Attachment,
          where: a.vault_id == ^vault_id,
          order_by: [asc: a.id]
        ),
        skip_tenant_check: true
      )

    note_entries =
      Enum.map(notes, fn note ->
        Zstream.entry("notes/note-#{note.id}.md", [note_payload(note)])
      end)

    attachment_entries =
      Enum.map(attachments, fn att ->
        Zstream.entry("attachments/attachment-#{att.id}.bin", [attachment_payload(att)])
      end)

    note_entries ++ attachment_entries
  end

  # TODO(Task 13): decrypt via the user's DEK + emit the real markdown
  # body. For now we ship the ciphertext so the multipart pipeline gets
  # exercised end-to-end without a half-built decrypt path.
  defp note_payload(%Note{content_ciphertext: nil}), do: ""
  defp note_payload(%Note{content_ciphertext: ct}) when is_binary(ct), do: ct

  defp attachment_payload(%Attachment{content: bin}) when is_binary(bin), do: bin
  defp attachment_payload(_), do: ""

  # Consumes the zstream chunk stream, flushing S3 parts every
  # @min_part_bytes. Returns {total_bytes_uploaded, parts_list}, where
  # parts_list is the `[%{part_number: integer, etag: binary}]` shape
  # the Storage.complete_multipart_upload/3 callback expects.
  defp stream_to_multipart(stream, storage, key, upload_id) do
    {buf, part_no, acc_parts, total} =
      Enum.reduce(stream, {<<>>, 1, [], 0}, fn chunk, {buf, part_no, acc_parts, total} ->
        chunk = IO.iodata_to_binary(chunk)
        buf = buf <> chunk

        if byte_size(buf) >= @min_part_bytes do
          {:ok, etag} = storage.upload_part(key, upload_id, part_no, buf)

          {<<>>, part_no + 1,
           acc_parts ++ [%{part_number: part_no, etag: etag}],
           total + byte_size(buf)}
        else
          {buf, part_no, acc_parts, total}
        end
      end)

    finalize_buffer(buf, part_no, acc_parts, total, storage, key, upload_id)
  end

  # S3 multipart upload requires ≥ 1 part. If the zstream produced
  # nothing buffered (empty vault), flush an empty final part so the
  # uploadId can be completed; AWS accepts a zero-byte final part.
  defp finalize_buffer(<<>>, _part_no, [], total, storage, key, upload_id) do
    {:ok, etag} = storage.upload_part(key, upload_id, 1, <<>>)
    {total, [%{part_number: 1, etag: etag}]}
  end

  defp finalize_buffer(<<>>, _part_no, parts, total, _storage, _key, _upload_id) do
    {total, parts}
  end

  defp finalize_buffer(buf, part_no, parts, total, storage, key, upload_id) do
    {:ok, etag} = storage.upload_part(key, upload_id, part_no, buf)
    {total + byte_size(buf), parts ++ [%{part_number: part_no, etag: etag}]}
  end

  defp part_key(export, vault, idx, of) do
    "exports/#{export.user_id}/#{export.id}/#{vault.slug}.part-#{idx}of#{of}.zip"
  end
end
