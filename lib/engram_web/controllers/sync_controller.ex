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
    description: "Every live note + attachment path and content hash, for sync reconciliation.",
    responses: [ok: {"Manifest", "application/json", Schemas.ManifestResponse}]
  )

  def manifest(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

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
      {:ok, dek} -> render_manifest(conn, user, vault, dek)
      {:error, :no_dek} -> render_empty_manifest(conn, user, vault)
    end
  end

  @doc """
  Unified ordered change-log pull. Merges the per-table seq feeds (notes +
  attachments) into one `(seq, id)`-ordered page, tags each entry with its
  `type`, and returns an opaque `next_cursor` + `has_more`.

  Per-vault `seq` is globally unique across notes AND attachments (both draw
  from `Vaults.next_seq!/1`), so sorting the union by `{seq, id}` is a total
  order — no note/attachment seq collisions.

  Pull-carries-ack: records the device watermark from the *incoming* cursor
  (what the client has durably applied), NOT the new page's max seq.
  """
  operation(:changes,
    operation_id: "sync-changes",
    summary: "Pull the unified note + attachment change feed",
    tags: ["Sync"],
    parameters: [
      limit: [in: :query, type: :integer, required: false, description: "Max rows (≤500)"],
      fields: [in: :query, type: :string, required: false, description: "\"meta\" or \"all\""],
      cursor: [in: :query, type: :string, required: false, description: "Opaque keyset cursor"]
    ],
    responses: [
      ok: {"Changes page", "application/json", Schemas.SyncChangesResponse},
      bad_request: {"Invalid cursor", "application/json", Schemas.MessageError},
      gone: {"Cursor older than retention window", "application/json", Schemas.MessageError}
    ]
  )

  def changes(conn, params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    device_id = conn |> get_req_header("x-device-id") |> List.first()
    limit = parse_limit(params["limit"])
    fields = parse_fields(params["fields"])

    case Engram.Sync.decode_cursor(params["cursor"]) do
      {:ok, cursor} ->
        render_changes(conn, user, vault, device_id, cursor || {0, nil}, limit, fields)

      {:error, :invalid_cursor} ->
        conn |> put_status(400) |> json(%{error: "invalid_cursor"})
    end
  end

  defp render_changes(conn, user, vault, device_id, {after_seq, after_id}, limit, fields) do
    if after_seq < Engram.Sync.retention_floor(vault) do
      conn |> put_status(410) |> json(%{error: "history_expired"})
    else
      # Fetch limit+1 from EACH table so the merged page can still fill
      # `limit` even if one feed is entirely consumed within the window.
      {:ok, %{changes: notes, has_more: notes_more}} =
        Engram.Notes.list_changes_by_seq(user, vault, after_seq,
          after_id: after_id,
          limit: limit + 1,
          fields: fields
        )

      # Attachments carry no note content, so the `fields` projection is n/a here.
      {:ok, %{changes: atts, has_more: atts_more}} =
        Engram.Attachments.list_changes_by_seq(user, vault, after_seq,
          after_id: after_id,
          limit: limit + 1
        )

      merged =
        (Enum.map(notes, &Map.put(&1, :type, "note")) ++
           Enum.map(atts, &Map.put(&1, :type, "attachment")))
        |> Enum.sort_by(&{&1.seq, &1.id})

      {page, has_more} =
        if length(merged) > limit do
          {Enum.take(merged, limit), true}
        else
          {merged, notes_more or atts_more}
        end

      next_cursor =
        if has_more do
          last = List.last(page)
          Engram.Sync.encode_cursor(last.seq, last.id)
        end

      # The cursor the client *sent* is what it has durably applied; record
      # that as the watermark (no-op when device_id is nil/blank).
      :ok = Engram.Sync.record_cursor(user, vault, device_id, after_seq)

      json(conn, %{changes: page, next_cursor: next_cursor, has_more: has_more})
    end
  end

  # Both seq feeds hard-cap their own page at 500 rows. The controller MUST
  # clamp to the same ceiling: each feed is fetched with `limit + 1`, and that
  # +1 probe is what lets the merge detect "more rows exist" and trim safely.
  # If the controller allowed a larger limit, a feed could return its capped
  # 500 (< limit) while more in-range rows remain, the merge would skip the
  # trim branch, and `next_cursor` would jump past those rows — silently
  # dropping them from the pull. Keep this in lockstep with the feed caps.
  @max_page_limit 500

  defp parse_limit(nil), do: @max_page_limit

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 -> min(n, @max_page_limit)
      _ -> @max_page_limit
    end
  end

  # Lenient by design: only "meta" opts into the content-stripped feed; any
  # other/unknown value (incl. a future client's value) falls back to the full
  # feed rather than 400ing. Unlike notes_controller's parse_changes_fields/1,
  # this endpoint favors forward-compat degrade over strict rejection.
  defp parse_fields("meta"), do: :meta
  defp parse_fields(_), do: :all

  defp render_empty_manifest(conn, user, vault) do
    json(conn, %{
      notes: [],
      attachments: [],
      total_notes: 0,
      total_attachments: 0,
      change_seq: Engram.Vaults.current_seq(user.id, vault.id)
    })
  end

  defp render_manifest(conn, user, vault, dek) do
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
            select: {n.id, n.dek_version, n.path_ciphertext, n.path_nonce, n.content_hash}
          )
        )
      end)

    {:ok, attachment_rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(a in Attachment,
            where: a.user_id == ^user.id and a.vault_id == ^vault.id and is_nil(a.deleted_at),
            select: {a.id, a.dek_version, a.path_ciphertext, a.path_nonce, a.content_hash}
          )
        )
      end)

    # Path-sized payloads decrypt in ~4µs each — measured 10k sequential at
    # ~43ms while chunked parallel came out *slower* (result copy-back to the
    # caller's heap rivals the AES-GCM work). Keep these loops sequential;
    # the batch telemetry tells us if a real-world vault disagrees.
    notes =
      Crypto.measure_decrypt_batch(:manifest_notes, length(note_rows), fn ->
        Enum.map(note_rows, fn {id, dek_version, path_ct, path_nonce, hash} ->
          aad = path_aad(:notes, id, dek_version)
          path = decrypt_path!(path_ct, path_nonce, dek, aad)
          %{path: path, content_hash: hash}
        end)
      end)
      |> Enum.sort_by(& &1.path)

    attachments =
      Crypto.measure_decrypt_batch(:manifest_attachments, length(attachment_rows), fn ->
        Enum.map(attachment_rows, fn {id, dek_version, path_ct, path_nonce, hash} ->
          aad = path_aad(:attachments, id, dek_version)
          path = decrypt_path!(path_ct, path_nonce, dek, aad)
          %{path: path, content_hash: hash}
        end)
      end)
      |> Enum.sort_by(& &1.path)

    json(conn, %{
      notes: notes,
      attachments: attachments,
      total_notes: length(notes),
      total_attachments: length(attachments),
      change_seq: Engram.Vaults.current_seq(user.id, vault.id)
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
