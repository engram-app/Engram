defmodule EngramWeb.SyncController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Notes.Note
  alias Engram.Repo
  alias EngramWeb.Schemas

  operation(:manifest,
    operation_id: "sync-manifest",
    summary: "Get the full vault manifest",
    tags: ["Sync"],
    description:
      "Every live note + attachment path, content hash, and change seq, for sync " <>
        "reconciliation. Pass `since_seq` (the `change_seq` of a previous manifest) to " <>
        "short-circuit: when nothing has changed the response is just " <>
        "`{unchanged: true, change_seq}` with the body omitted.",
    parameters: [
      since_seq: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Watermark from a prior manifest's `change_seq`; invalid values are ignored.",
        example: "1042"
      ]
    ],
    responses: [ok: {"Manifest", "application/json", Schemas.ManifestResponse}]
  )

  def manifest(conn, params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    current = Engram.Vaults.current_seq(user.id, vault.id)

    # Phase E1 (#1065): when the client's last-validated watermark still equals
    # the vault's change_seq, nothing in the vault has changed — skip the
    # decrypt-heavy full render entirely. Invalid/absent since_seq falls
    # through to the full manifest, never errors.
    if parse_since_seq(params["since_seq"]) == current do
      json(conn, %{unchanged: true, change_seq: current})
    else
      # Phase B.3: paths live only as ciphertext. Project ONLY the columns we
      # need (path ciphertext + nonce + content_hash) so a 10k-note vault
      # doesn't pull megabyte-sized `content_ciphertext` blobs into BEAM.
      # Decrypt path Elixir-side, then sort. Older `select: n` shape pulled
      # full rows + sorted in Elixir — measurable OOM risk on the largest
      # vault under load.
      # No DEK = brand-new user with zero writes. No notes/attachments are
      # possible without a DEK (every upsert provisions one), so short-circuit
      # to an empty manifest instead of crashing on `{:ok, dek}` match.
      case Crypto.get_dek(user) do
        {:ok, dek} -> render_manifest(conn, user, vault, dek, current)
        {:error, :no_dek} -> render_empty_manifest(conn, current)
      end
    end
  end

  defp parse_since_seq(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_since_seq(_), do: nil

  defp render_empty_manifest(conn, current_seq) do
    json(conn, %{
      notes: [],
      attachments: [],
      total_notes: 0,
      total_attachments: 0,
      change_seq: current_seq
    })
  end

  defp render_manifest(conn, user, vault, dek, current_seq) do
    # T3.6 — project `id` and `dek_version` so AAD-bound rows (v ≥ 2) can
    # reconstruct the bind string ("notes:path:<id>" / "attachments:path:<id>")
    # at decrypt time. Legacy rows (v = 1) decrypt with empty AAD.
    {:ok, note_rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where:
              n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
                n.kind == "note",
            select:
              {n.id, n.dek_version, n.path_ciphertext, n.path_nonce, n.content_hash, n.seq,
               n.crdt_head}
          )
        )
      end)

    {:ok, attachment_rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(a in Attachment,
            where: a.user_id == ^user.id and a.vault_id == ^vault.id and is_nil(a.deleted_at),
            select: {a.id, a.dek_version, a.path_ciphertext, a.path_nonce, a.content_hash, a.seq}
          )
        )
      end)

    # Path-sized payloads decrypt in ~4µs each — measured 10k sequential at
    # ~43ms while chunked parallel came out *slower* (result copy-back to the
    # caller's heap rivals the AES-GCM work). Keep these loops sequential;
    # the batch telemetry tells us if a real-world vault disagrees.
    notes =
      Crypto.measure_decrypt_batch(:manifest_notes, length(note_rows), fn ->
        Enum.map(note_rows, fn {id, dek_version, path_ct, path_nonce, hash, seq, crdt_head} ->
          aad = path_aad(:notes, id, dek_version)
          path = decrypt_path!(path_ct, path_nonce, dek, aad)
          %{id: id, path: path, content_hash: hash, seq: seq, crdt_head: crdt_head}
        end)
      end)
      |> Enum.sort_by(& &1.path)

    attachments =
      Crypto.measure_decrypt_batch(:manifest_attachments, length(attachment_rows), fn ->
        Enum.map(attachment_rows, fn {id, dek_version, path_ct, path_nonce, hash, seq} ->
          aad = path_aad(:attachments, id, dek_version)
          path = decrypt_path!(path_ct, path_nonce, dek, aad)
          %{id: id, path: path, content_hash: hash, seq: seq}
        end)
      end)
      |> Enum.sort_by(& &1.path)

    json(conn, %{
      notes: notes,
      attachments: attachments,
      total_notes: length(notes),
      total_attachments: length(attachments),
      change_seq: current_seq
    })
  end

  defp path_aad(table, id, dek_version) when is_integer(dek_version) and dek_version >= 2,
    do: Crypto.aad_for_row(table, :path, id)

  defp path_aad(_table, _id, _v), do: <<>>

  defp decrypt_path!(ciphertext, nonce, dek, aad) do
    case Envelope.decrypt(ciphertext, nonce, dek, aad) do
      {:ok, path} -> path
      :error -> raise "manifest path decrypt failed — possible data corruption"
    end
  end
end
