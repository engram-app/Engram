defmodule EngramWeb.AttachmentsController do
  use EngramWeb, :controller

  alias Engram.Attachments
  alias Engram.Billing
  alias Engram.Storage.MimeWhitelist

  # Free-tier launch §4.5 — attachments are a paid-tier feature. Gate at the
  # top of the upload action so Free users 402 BEFORE any S3 work, file
  # parsing, or DB allocation. `attachments_enabled` resolves through the
  # same plan/override pipeline as every other limit key.
  def upload(conn, params) do
    user = conn.assigns.current_user

    case Billing.check_feature(user, :attachments_enabled) do
      :ok ->
        do_upload_gated(conn, user, params)

      {:error, :feature_not_available} ->
        EngramWeb.LimitResponse.halt(
          conn,
          "attachments_disabled",
          :attachments_enabled,
          false,
          nil
        )
    end
  end

  defp do_upload_gated(conn, user, params) do
    vault = conn.assigns.current_vault
    path = params["path"] || params[:path]
    explicit_mime = params["mime_type"] || params[:mime_type]
    effective_mime = explicit_mime || MimeWhitelist.detect_mime(path)

    # Free's text-only attachment gate sits AHEAD of the generic
    # MimeWhitelist so we surface the upgrade path (402) instead of
    # the "this file is rejected globally" shape (415). Paid users skip
    # this branch entirely.
    if text_only?(user) and not text_mime?(effective_mime) do
      EngramWeb.LimitResponse.halt(
        conn,
        "attachment_must_be_text",
        :attachments_text_only,
        true,
        nil
      )
    else
      case MimeWhitelist.check(effective_mime, path) do
        {:error, {:mime_not_allowed, mime}} ->
          conn
          |> put_status(415)
          |> json(%{error: "mime_not_allowed", mime_type: mime})

        {:error, {:extension_not_allowed, ext}} ->
          conn
          |> put_status(415)
          |> json(%{error: "extension_not_allowed", extension: ext})

        :ok ->
          do_upload(conn, user, vault, params)
      end
    end
  end

  defp text_only?(user), do: Billing.effective_limit(user, :attachments_text_only) == true

  defp text_mime?(nil), do: false

  defp text_mime?(mime) when is_binary(mime),
    do: String.starts_with?(String.downcase(mime), "text/")

  defp do_upload(conn, user, vault, params) do
    case Attachments.upsert_attachment(user, vault, params) do
      {:ok, att} ->
        json(conn, %{attachment: serialize_metadata(att)})

      {:error, :invalid_base64} ->
        conn |> put_status(400) |> json(%{error: "invalid base64 content"})

      {:error, :missing_content} ->
        conn |> put_status(422) |> json(%{error: "content_base64 is required"})

      {:error, {:too_large, limit}} ->
        # Free-tier launch §4.5 — single file over per-plan max_file_bytes.
        EngramWeb.LimitResponse.halt(
          conn,
          "file_too_large",
          :max_file_bytes,
          limit,
          nil
        )

      {:error, {:storage_cap_reached, used, limit}} ->
        # Free-tier launch §4.5 — paid user over lifetime attachment quota.
        EngramWeb.LimitResponse.halt(
          conn,
          "attachments_quota_exceeded",
          :attachment_bytes_cap,
          limit,
          used
        )

      {:error, {:storage, _reason}} ->
        conn |> put_status(502) |> json(%{error: "failed to upload to storage backend"})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{errors: format_errors(changeset)})
    end
  end

  def index(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    {:ok, atts} = Attachments.list_attachments(user, vault)

    json(conn, %{
      attachments:
        Enum.map(atts, fn a ->
          %{
            id: a.id,
            path: a.path,
            mime_type: a.mime_type,
            size_bytes: a.size_bytes,
            mtime: a.mtime,
            updated_at: a.updated_at
          }
        end)
    })
  end

  def show(conn, %{"path" => path_parts} = params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    path = Path.join(path_parts)

    case Attachments.get_attachment(user, vault, path) do
      {:ok, nil} ->
        conn |> put_status(404) |> json(%{error: "attachment not found"})

      {:ok, att} ->
        if params["raw"] == "1" do
          # Raw bytes are served from the API origin. nosniff (set on the :api
          # pipeline) stops content-type confusion, but a declared text/html or
          # image/svg+xml still renders inline — and SVG can carry script — if a
          # user navigates straight to the raw URL. Force those to download;
          # everything else (images, PDF) may render inline for preview.
          disposition =
            if att.mime_type in ["text/html", "image/svg+xml"], do: "attachment", else: "inline"

          conn
          |> put_resp_content_type(att.mime_type || "application/octet-stream")
          |> put_resp_header(
            "content-disposition",
            ~s(#{disposition}; filename="#{Path.basename(att.path)}")
          )
          |> send_resp(200, att.content)
        else
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
        end

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
