defmodule EngramWeb.SyncController do
  use EngramWeb, :controller

  import Ecto.Query

  alias Engram.Repo
  alias Engram.Crypto
  alias Engram.Notes.Note
  alias Engram.Attachments.Attachment

  def manifest(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    {:ok, note_rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(n in Note,
            where: n.user_id == ^user.id and n.vault_id == ^vault.id and is_nil(n.deleted_at),
            select: n
          )
        )
      end)

    {:ok, attachment_rows} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(
          from(a in Attachment,
            where: a.user_id == ^user.id and a.vault_id == ^vault.id and is_nil(a.deleted_at),
            select: a
          )
        )
      end)

    # Phase B.3: paths live only as ciphertext in Postgres. Decrypt each row's
    # path Elixir-side, then trim to the manifest's {path, content_hash} shape
    # and sort by path. Avoids leaking ciphertext into the response.
    notes =
      note_rows
      |> Enum.map(fn n ->
        {:ok, decrypted} = Crypto.maybe_decrypt_note_fields(n, user)
        %{path: decrypted.path, content_hash: n.content_hash}
      end)
      |> Enum.sort_by(& &1.path)

    attachments =
      attachment_rows
      |> Enum.map(fn a ->
        {:ok, decrypted} = Crypto.maybe_decrypt_attachment_fields(a, user)
        %{path: decrypted.path, content_hash: a.content_hash}
      end)
      |> Enum.sort_by(& &1.path)

    json(conn, %{
      notes: notes,
      attachments: attachments,
      total_notes: length(notes),
      total_attachments: length(attachments)
    })
  end
end
