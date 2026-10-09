defmodule EngramWeb.SyncController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.PathCrypto
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Repo
  alias EngramWeb.Schemas

  require Logger

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
    since = parse_since_seq(params["since_seq"])

    # Phase E1 (#1065): when the client's last-validated watermark still equals
    # the vault's change_seq, nothing in the vault has changed — skip the
    # decrypt-heavy full render entirely. Invalid/absent since_seq falls
    # through to the full manifest, never errors. One transaction reads the
    # seq and, only when it moved, the rows (see manifest_rows/2).
    {current, rows} =
      Repo.with_tenant!(user.id, fn ->
        current = Engram.Vaults.raw_current_seq(vault.id)

        if since == current,
          do: {current, :unchanged},
          else: {current, manifest_rows(user, vault)}
      end)

    if rows == :unchanged do
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
        {:ok, dek} ->
          render_manifest(conn, rows, dek, current)

        {:error, :no_dek} ->
          render_empty_manifest(conn, current)

        {:error, reason} ->
          # Anything else (:unrecognised_blob, a propagated unwrap_dek/2
          # failure) is a real crypto fault, not "this vault is empty".
          # Reaching render_empty_manifest here would be worse than a 500:
          # the plugin diffs this manifest against the local vault, so an
          # empty one reads as "every note was deleted remotely". Fail
          # loudly. Previously fell through to a CaseClauseError — same
          # 500, but with nothing logged to diagnose it.
          Logger.error(
            "sync manifest: DEK unavailable, refusing to render",
            Metadata.with_category(:error, :crypto,
              user_id: user.id,
              vault_id: vault.id,
              reason: Crypto.format_dek_error(reason)
            )
          )

          raise "sync manifest: DEK unavailable (#{Crypto.format_dek_error(reason)})"
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

  # MUST run inside the caller's with_tenant block.
  defp manifest_rows(user, vault) do
    # T3.6 — project `id` and `dek_version` so AAD-bound rows (v ≥ 2) can
    # reconstruct the bind string ("notes:path:<id>" / "attachments:path:<id>")
    # at decrypt time. Legacy rows (v = 1) decrypt with empty AAD.
    #
    # #1211: both fetches share the caller's with_tenant block (with the seq
    # read): they are adjacent, DB-only reads with nothing CPU-bound between
    # them. Decrypt (render_manifest/4) stays OUTSIDE the block on purpose:
    # holding a DB connection across CPU-bound decrypt work is the shape
    # behind the 2026-07-09 CRDT pool-exhaustion incident.
    notes =
      Repo.all(
        from(n in Note,
          where:
            n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at) and
              n.kind == "note",
          select:
            {n.id, fragment("uuid_send(?)", n.id), n.dek_version, n.path_ciphertext, n.path_nonce,
             n.content_hash, n.seq, n.crdt_head}
        )
      )

    attachments =
      Repo.all(
        from(a in Attachment,
          where: a.user_id == ^user.id and a.vault_id == ^vault.id and is_nil(a.deleted_at),
          select:
            {a.id, fragment("uuid_send(?)", a.id), a.dek_version, a.path_ciphertext, a.path_nonce,
             a.content_hash, a.seq}
        )
      )

    {notes, attachments}
  end

  defp render_manifest(conn, {note_rows, attachment_rows}, dek, current_seq) do
    # One batch native call per column (`PathCrypto.decrypt_many!/3`): one key
    # schedule, AAD built in Rust from the raw ids selected above. Measured
    # 2-5x the per-row loop (docs/context/native-nifs.md). Parallel was
    # slower: copying results back rivals the AES-GCM work.
    notes =
      Crypto.measure_decrypt_batch(:manifest_notes, length(note_rows), fn ->
        fields =
          Enum.map(note_rows, fn {_, raw, v, ct, nonce, _, _, _} -> {raw, v, ct, nonce} end)

        Enum.zip_with(note_rows, PathCrypto.decrypt_many!(:notes, fields, dek), fn
          {id, _, _, _, _, hash, seq, crdt_head}, path ->
            %{id: id, path: path, content_hash: hash, seq: seq, crdt_head: crdt_head}
        end)
      end)
      |> Enum.sort_by(& &1.path)

    attachments =
      Crypto.measure_decrypt_batch(:manifest_attachments, length(attachment_rows), fn ->
        fields =
          Enum.map(attachment_rows, fn {_, raw, v, ct, nonce, _, _} -> {raw, v, ct, nonce} end)

        Enum.zip_with(attachment_rows, PathCrypto.decrypt_many!(:attachments, fields, dek), fn
          {id, _, _, _, _, hash, seq}, path -> %{id: id, path: path, content_hash: hash, seq: seq}
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
end
