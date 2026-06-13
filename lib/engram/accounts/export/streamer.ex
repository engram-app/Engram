defmodule Engram.Accounts.Export.Streamer do
  @moduledoc """
  Zips one vault per archive and streams it into an S3 multipart upload,
  returning the s3_keys list the `account_exports` row records.

  ## MVP scope (Task 12)

  Happy path only — one part per vault (`part: 1, of: 1`). The 10 GB part
  split and decryption of note bodies are stubbed pending Task 13/14.
  See the per-helper notes below for TODOs.

  Attachments are **not** written to the zip. The `Attachment.content`
  field is virtual (it's fetched from S3 lazily by
  `Engram.Crypto.maybe_decrypt_attachment_fields/2`), so a plain
  `Repo.all` here would emit zero-byte entries. Task 13 will wire the
  real S3-fetch-and-decrypt path; until then attachments are deferred
  entirely — no zip entries are written for them.

  Empty vaults (no notes, no attachments) skip the multipart upload
  altogether: AWS S3 would accept a sole 0-byte part, but MinIO and
  Garage reject `CompleteMultipartUpload` on a zero-byte sole part. A
  user with only empty vaults therefore ends with `s3_keys: []` —
  `mark_ready` still flips the status to `:ready`, and any subsequent
  `mint_download_url` call returns `{:error, :no_such_part}`.

  Filenames inside the zip use `vault.slug` rather than the decrypted
  `vault.name` because note paths are encrypted (Phase B.3) and we don't
  yet hand the streamer a DEK; the same slug is also what appears in the
  s3 key so the user can correlate the download to the vault they
  recognise in the UI.
  """

  import Ecto.Query

  alias Engram.Accounts.Export.Schema
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
  @spec run(Schema.t(), keyword()) :: {:ok, [part_map()], non_neg_integer()}
  def run(%Schema{user_id: user_id} = export, _opts) do
    vaults =
      Repo.all(
        from(v in Vault,
          where: v.user_id == ^user_id and is_nil(v.deleted_at),
          order_by: [asc: v.id]
        ),
        skip_tenant_check: true
      )

    {acc_parts, total} =
      Enum.reduce(vaults, {[], 0}, fn vault, {acc_parts, acc_bytes} ->
        {vault_parts, vault_bytes} = zip_vault(export, vault)
        {[vault_parts | acc_parts], acc_bytes + vault_bytes}
      end)

    parts =
      acc_parts
      |> Enum.reverse()
      |> List.flatten()

    {:ok, parts, total}
  end

  # MVP: one part per vault. Task 14 will split at @part_max_bytes (10 GB).
  #
  # Short-circuits before opening the multipart upload when the vault
  # has no entries to emit. This is the MinIO/Garage gate — those
  # backends reject `CompleteMultipartUpload` on a zero-byte sole part.
  defp zip_vault(export, vault) do
    case zip_entries(export, vault) do
      [] ->
        {[], 0}

      entries ->
        storage = Storage.adapter()
        key = part_key(export, vault, 1, 1)

        {:ok, upload_id} = storage.start_multipart(key)

        {total_bytes, finished_parts} =
          entries
          |> Zstream.zip()
          |> stream_to_multipart(storage, key, upload_id)

        if total_bytes == 0 do
          # Zstream emitted only EOCD framing (no actual entries). Abort
          # rather than complete the upload — same MinIO/Garage rationale
          # as the empty-entries short-circuit above.
          :ok = storage.abort_multipart_upload(key, upload_id)
          {[], 0}
        else
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
    end
  end

  # Build the zstream entry list for a vault. MVP: notes are emitted as
  # opaque ciphertext blobs because we don't have a DEK in scope (Task
  # 13 wires decryption). Attachments are NOT emitted — see the
  # moduledoc for why. Filenames use the row id so the zip remains
  # deterministic and `.obsidian/`-filtering work in Task 14 has clean
  # paths to match against once we decrypt.
  defp zip_entries(%Schema{user_id: user_id}, %Vault{id: vault_id}) do
    notes =
      Repo.all(
        from(n in Note,
          # RLS is bypassed (skip_tenant_check), so the explicit user_id clause
          # is the sole guarantee that one tenant's export never includes
          # another tenant's rows — it MUST NOT be removed.
          where:
            n.user_id == ^user_id and
              n.vault_id == ^vault_id and
              n.kind == "note" and
              is_nil(n.deleted_at),
          order_by: [asc: n.id]
        ),
        skip_tenant_check: true
      )

    Enum.map(notes, fn note ->
      Zstream.entry("notes/note-#{note.id}.md", [note_payload(note)])
    end)
  end

  # Decryption via the user's DEK lands in Plan Task 13; until then we
  # ship the ciphertext so the multipart pipeline gets exercised
  # end-to-end without a half-built decrypt path.
  defp note_payload(%Note{content_ciphertext: nil}), do: ""
  defp note_payload(%Note{content_ciphertext: ct}) when is_binary(ct), do: ct

  # Consumes the zstream chunk stream, flushing S3 parts every
  # @min_part_bytes. Returns {total_bytes_uploaded, parts_list}, where
  # parts_list is the `[%{part_number: integer, etag: binary}]` shape
  # the Storage.complete_multipart_upload/3 callback expects, in
  # ascending part_number order.
  defp stream_to_multipart(stream, storage, key, upload_id) do
    {buf, part_no, acc_parts, total} =
      Enum.reduce(stream, {<<>>, 1, [], 0}, fn chunk, {buf, part_no, acc_parts, total} ->
        chunk = IO.iodata_to_binary(chunk)
        buf = buf <> chunk

        if byte_size(buf) >= @min_part_bytes do
          {:ok, etag} = storage.upload_part(key, upload_id, part_no, buf)

          {<<>>, part_no + 1, [%{part_number: part_no, etag: etag} | acc_parts],
           total + byte_size(buf)}
        else
          {buf, part_no, acc_parts, total}
        end
      end)

    finalize_buffer(buf, part_no, acc_parts, total, storage, key, upload_id)
  end

  # Returns parts in ascending part_number order. Both branches that
  # emit parts prepend onto `acc_parts` (kept in descending order during
  # the reduce in `stream_to_multipart/4`) and then reverse once here.

  # No buffered bytes and no parts flushed — total is 0 (truly empty
  # zip stream). Caller (`zip_vault/2`) handles the abort.
  defp finalize_buffer(<<>>, _part_no, [], 0 = total, _storage, _key, _upload_id) do
    {total, []}
  end

  # Stream finished cleanly on a part boundary; nothing left to flush.
  defp finalize_buffer(<<>>, _part_no, acc_parts, total, _storage, _key, _upload_id) do
    {total, Enum.reverse(acc_parts)}
  end

  # Flush the trailing buffer as the final part.
  defp finalize_buffer(buf, part_no, acc_parts, total, storage, key, upload_id) do
    {:ok, etag} = storage.upload_part(key, upload_id, part_no, buf)

    parts =
      [%{part_number: part_no, etag: etag} | acc_parts]
      |> Enum.reverse()

    {total + byte_size(buf), parts}
  end

  defp part_key(export, vault, idx, of) do
    "exports/#{export.user_id}/#{export.id}/#{vault.slug}.part-#{idx}of#{of}.zip"
  end
end
