defmodule EngramWeb.AttachmentsController do
  use EngramWeb, :controller

  alias Engram.Attachments

  def upload(conn, params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    case Attachments.upsert_attachment(user, vault, params) do
      {:ok, att} ->
        json(conn, %{attachment: serialize_metadata(att)})

      {:error, :invalid_base64} ->
        conn |> put_status(400) |> json(%{error: "invalid base64 content"})

      {:error, :missing_content} ->
        conn |> put_status(422) |> json(%{error: "content_base64 is required"})

      {:error, :too_large} ->
        conn |> put_status(413) |> json(%{error: "attachment exceeds size limit"})

      {:error, {:storage, _reason}} ->
        conn |> put_status(502) |> json(%{error: "failed to upload to storage backend"})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
    end
  end

  def show(conn, %{"path" => path_parts}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    path = Path.join(path_parts)

    case Attachments.get_attachment(user, vault, path) do
      {:ok, nil} ->
        conn |> put_status(404) |> json(%{error: "attachment not found"})

      {:ok, att} ->
        json(conn, %{
          id: att.id,
          path: att.path,
          mime_type: att.mime_type,
          size_bytes: att.size_bytes,
          mtime: att.mtime,
          content_base64: Base.encode64(att.content),
          created_at: att.created_at,
          updated_at: att.updated_at
        })

      {:error, {:storage, _reason}} ->
        conn |> put_status(502) |> json(%{error: "failed to fetch attachment from storage"})

      {:error, _reason} ->
        conn |> put_status(500) |> json(%{error: "internal error fetching attachment"})
    end
  end

  def delete(conn, %{"path" => path_parts}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    path = Path.join(path_parts)

    Attachments.delete_attachment(user, vault, path)
    json(conn, %{deleted: true, path: path})
  end

  def changes(conn, %{"since" => since_str}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    case DateTime.from_iso8601(since_str) do
      {:ok, since, _offset} ->
        {:ok, changes} = Attachments.list_changes(user, vault, since)

        json(conn, %{
          changes:
            Enum.map(changes, fn c ->
              %{
                path: c.path,
                mime_type: c.mime_type,
                size_bytes: c.size_bytes,
                mtime: c.mtime,
                updated_at: c.updated_at,
                deleted: c.deleted_at != nil
              }
            end),
          server_time: DateTime.utc_now() |> DateTime.to_iso8601()
        })

      {:error, _} ->
        conn |> put_status(400) |> json(%{error: "invalid ISO 8601 timestamp"})
    end
  end

  def changes(conn, _params) do
    conn |> put_status(400) |> json(%{error: "since parameter is required"})
  end

  defp format_errors(changeset), do: EngramWeb.format_errors(changeset)

  defp serialize_metadata(att) do
    %{
      id: att.id,
      path: att.path,
      mime_type: att.mime_type,
      size_bytes: att.size_bytes,
      mtime: att.mtime,
      created_at: att.created_at,
      updated_at: att.updated_at
    }
  end
end
