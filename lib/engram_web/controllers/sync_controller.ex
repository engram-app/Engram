defmodule EngramWeb.SyncController do
  use EngramWeb, :controller

  import Ecto.Query

  alias Engram.Repo
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Notes.Note
  alias Engram.Attachments.Attachment

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
      {:error, :no_dek} -> render_empty_manifest(conn)
    end
  end

  defp render_empty_manifest(conn) do
    json(conn, %{notes: [], attachments: [], total_notes: 0, total_attachments: 0})
  end

  defp render_manifest(conn, user, vault, dek) do
    # T3.6 — project `id` and `dek_version` so AAD-bound rows (v ≥ 2) can
    # reconstruct the bind string ("notes:path:<id>" / "attachments:path:<id>")
    # at decrypt time. Legacy rows (v = 1) decrypt with empty AAD.
    {:ok, note_rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where: n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at),
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

    notes =
      note_rows
      |> Enum.map(fn {id, dek_version, path_ct, path_nonce, hash} ->
        aad = path_aad(:notes, id, dek_version)
        path = decrypt_path!(path_ct, path_nonce, dek, aad)
        %{path: path, content_hash: hash}
      end)
      |> Enum.sort_by(& &1.path)

    attachments =
      attachment_rows
      |> Enum.map(fn {id, dek_version, path_ct, path_nonce, hash} ->
        aad = path_aad(:attachments, id, dek_version)
        path = decrypt_path!(path_ct, path_nonce, dek, aad)
        %{path: path, content_hash: hash}
      end)
      |> Enum.sort_by(& &1.path)

    json(conn, %{
      notes: notes,
      attachments: attachments,
      total_notes: length(notes),
      total_attachments: length(attachments)
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
