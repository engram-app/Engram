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

  def rename(conn, %{"old_path" => old_path, "new_path" => new_path}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    with :ok <- Billing.check_feature(user, :attachments_enabled),
         {:ok, att} <- Attachments.move_attachment(user, vault, old_path, new_path) do
      json(conn, %{
        renamed: true,
        old_path: old_path,
        new_path: new_path,
        attachment: serialize_metadata(att)
      })
    else
      {:error, :feature_not_available} ->
        EngramWeb.LimitResponse.halt(conn, "attachments_disabled", :attachments_enabled, false, nil)

      {:error, :conflict} ->
        conn |> put_status(409) |> json(%{error: "conflict"})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "not_found"})
    end
  end

  def batch_move(conn, %{"paths" => paths, "target_folder" => target}) when is_list(paths) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    # Gated like rename/upload: moving attachments is "using" the feature, so a
    # plan without :attachments_enabled gets a 402 (delete stays ungated below).
    case Billing.check_feature(user, :attachments_enabled) do
      {:error, :feature_not_available} ->
        EngramWeb.LimitResponse.halt(conn, "attachments_disabled", :attachments_enabled, false, nil)

      :ok ->
        case Attachments.batch_move(user, vault, paths, target) do
          {:ok, %{moved: n}} ->
            body = %{moved: n}
            Engram.Idempotency.remember(conn.assigns.idempotency_key, %{status: 200, body: body})
            json(conn, body)

          {:error, {:conflict, p}} ->
            conn |> put_status(409) |> json(%{error: "conflict", item_path: p})

          {:error, {:not_found, p}} ->
            conn |> put_status(404) |> json(%{error: "not_found", item_path: p})

          {:error, _} ->
            conn |> put_status(500) |> json(%{error: "internal"})
        end
    end
  end

  def batch_move(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required params: paths, target_folder"})
  end

  # Intentionally NOT billing-gated: deleting is cleanup, never trap a downgraded
  # user with attachments they can't remove. Mirrors notes-delete staying open.
  def batch_delete(conn, %{"paths" => paths}) when is_list(paths) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    # batch_delete/3 is total — its @spec returns {:ok, %{deleted: _}} only.
    {:ok, %{deleted: n}} = Attachments.batch_delete(user, vault, paths)
    body = %{deleted: n}
    Engram.Idempotency.remember(conn.assigns.idempotency_key, %{status: 200, body: body})
    json(conn, body)
  end

  def batch_delete(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required param: paths"})
  end

  def index(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    # The whole tree sidebar depends on this; handle a list failure explicitly
    # (logged 500 body) instead of a bare-match MatchError stacktrace.
    case Attachments.list_attachments(user, vault) do
      {:ok, atts} ->
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

      {:error, reason} ->
        require Logger
        Logger.error("Failed to list attachments", vault_id: vault.id, reason: inspect(reason))
        conn |> put_status(500) |> json(%{error: "failed to list attachments"})
    end
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
          # pipeline) stops content-type confusion, but a declared inline type
          # still renders in the browser — and HTML/SVG/XML can execute script
          # (SVG <script>, XML via xml-stylesheet/XSLT). The MIME whitelist admits
          # the whole `text/` prefix, so an allowlist of types known-safe to
          # render inline is the correct gate; everything else force-downloads.
          disposition = if inline_safe?(att.mime_type), do: "inline", else: "attachment"
          # Strip control chars/quotes so a crafted filename can't break the
          # header (Plug rejects control chars → 500 otherwise).
          filename = String.replace(Path.basename(att.path), ~r/[[:cntrl:]"]/u, "")

          conn
          |> put_resp_content_type(att.mime_type || "application/octet-stream")
          |> put_resp_header("content-disposition", ~s(#{disposition}; filename="#{filename}"))
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

  # Types safe to render inline in the browser on the API origin. Raster images
  # and PDFs are inert; SVG (script via <script>) and HTML/XML (script via
  # markup or XSLT) are NOT — they force-download. Everything not on this list
  # downloads by default.
  defp inline_safe?(nil), do: false
  defp inline_safe?("image/svg+xml"), do: false

  defp inline_safe?(mime) when is_binary(mime) do
    String.starts_with?(mime, "image/") or mime == "application/pdf" or mime == "text/plain"
  end

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
