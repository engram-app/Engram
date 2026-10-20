defmodule EngramWeb.AttachmentUploadsController do
  @moduledoc """
  Chunked (resumable) attachment uploads over `Engram.Attachments.Uploads`:
  start a session, PUT each part as raw bytes, then complete into a live
  attachment. Refusals answer in the same shapes as `POST /api/attachments`.
  """
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Engram.Attachments.Uploads
  alias Engram.Billing
  alias Engram.Storage.MimeWhitelist
  alias EngramWeb.AttachmentRefusalTelemetry
  alias EngramWeb.AttachmentsController
  alias EngramWeb.Plugs.SettleUnreadBody
  alias EngramWeb.RequestMeta
  alias EngramWeb.Schemas

  action_fallback EngramWeb.FallbackController

  plug AttachmentRefusalTelemetry when action in [:start, :put_part, :complete]

  @id_param [in: :path, type: :string, required: true, description: "Upload id"]

  operation(:start,
    operation_id: "attachment-uploads-start",
    summary: "Start a chunked attachment upload",
    description:
      "Opens a resumable upload for a file of `size_bytes`, refused up front with the same " <>
        "responses as `POST /api/attachments` (402 plan, size or quota, 415 executable " <>
        "extension, 422 invalid `mime_type`). Then PUT each part and complete. A storage " <>
        "backend without multipart support (self-host database storage) returns 501.",
    tags: ["Attachments"],
    request_body:
      {"File to upload", "application/json", Schemas.AttachmentUploadStartRequest, required: true},
    responses: [
      created: {"Session opened", "application/json", Schemas.AttachmentUploadSession},
      payment_required:
        {"Attachments require a paid plan / quota", "application/json", Schemas.LimitError},
      unsupported_media_type:
        {"Executable extension not allowed", "application/json", Schemas.MimeRejected},
      unprocessable_entity:
        {"Missing size or path, or invalid mime_type", "application/json", Schemas.Error},
      not_implemented:
        {"Storage backend has no multipart support", "application/json", Schemas.MessageError},
      bad_gateway: {"Storage backend failure", "application/json", Schemas.MessageError}
    ]
  )

  def start(conn, params) do
    user = conn.assigns.current_user

    with :ok <- feature(user),
         :ok <- text_gate(user, params),
         {:ok, up} <- Uploads.start(user, conn.assigns.current_vault, params) do
      conn
      |> put_status(201)
      |> json(%{upload_id: up.id, part_size: up.part_size, part_count: up.part_count})
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  operation(:put_part,
    operation_id: "attachment-uploads-put-part",
    summary: "Upload one part",
    description:
      "Stores part `n` (1-based) as raw `application/octet-stream` bytes. Every part is " <>
        "exactly `part_size` bytes except the last, which is the remainder; any other size " <>
        "returns 422 `bad_part_size` and a part number outside the session returns 422 " <>
        "`bad_part_number`. Re-sending a part replaces it. A body that stalls returns 408.",
    tags: ["Attachments"],
    parameters: [
      id: @id_param,
      n: [in: :path, type: :integer, required: true, description: "Part number, from 1"]
    ],
    request_body: %OpenApiSpex.RequestBody{
      description: "Part bytes",
      required: true,
      content: %{
        "application/octet-stream" => %OpenApiSpex.MediaType{
          schema: %OpenApiSpex.Schema{type: :string, format: :binary}
        }
      }
    },
    responses: [
      ok: {"Part stored", "application/json", Schemas.AttachmentUploadPart},
      not_found: {"No such upload", "application/json", Schemas.Error},
      request_timeout:
        {"Body stalled before it finished", "application/json", Schemas.MessageError},
      unprocessable_entity: {"Bad part number or size", "application/json", Schemas.Error},
      bad_gateway: {"Storage backend failure", "application/json", Schemas.MessageError}
    ]
  )

  def put_part(conn, %{"id" => id, "n" => n}) do
    limit = Uploads.part_size()

    with {:ok, n} <- part_number(n),
         :ok <- check_declared_length(conn, limit),
         {:ok, bytes, conn} <- read_part(conn, limit) do
      case Uploads.put_part(conn.assigns.current_user, conn.assigns.current_vault, id, n, bytes) do
        {:ok, part} -> json(conn, part)
        {:error, reason} -> refuse(conn, reason)
      end
    else
      {:halt, conn} -> conn
      {:error, reason} -> refuse(conn, reason)
    end
  end

  operation(:status,
    operation_id: "attachment-uploads-status",
    summary: "Which parts the server holds",
    description: "For a client resuming an upload: the part numbers already stored.",
    tags: ["Attachments"],
    parameters: [id: @id_param],
    responses: [
      ok: {"Upload state", "application/json", Schemas.AttachmentUploadStatus},
      not_found: {"No such upload", "application/json", Schemas.Error}
    ]
  )

  def status(conn, %{"id" => id}) do
    case Uploads.status(conn.assigns.current_user, conn.assigns.current_vault, id) do
      {:ok, status} -> json(conn, status)
      {:error, reason} -> refuse(conn, reason)
    end
  end

  operation(:complete,
    operation_id: "attachment-uploads-complete",
    summary: "Complete a chunked upload",
    description:
      "Assembles the parts into a live attachment and answers like `POST /api/attachments`. " <>
        "Returns 409 `missing_parts` (with the part numbers) while any part is missing, the " <>
        "session staying resumable, and 402 `attachments_quota_exceeded` when the file no " <>
        "longer fits the quota, the session then being dropped.",
    tags: ["Attachments"],
    parameters: [id: @id_param],
    responses: [
      ok: {"Uploaded", "application/json", Schemas.AttachmentResponse},
      payment_required: {"Quota exceeded", "application/json", Schemas.LimitError},
      not_found: {"No such upload", "application/json", Schemas.Error},
      conflict: {"Parts missing", "application/json", Schemas.AttachmentUploadMissingParts},
      bad_gateway: {"Storage backend failure", "application/json", Schemas.MessageError}
    ]
  )

  def complete(conn, %{"id" => id}) do
    case Uploads.complete(conn.assigns.current_user, conn.assigns.current_vault, id) do
      {:ok, att} -> json(conn, %{attachment: AttachmentsController.serialize_metadata(att)})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  operation(:abort,
    operation_id: "attachment-uploads-abort",
    summary: "Abandon a chunked upload",
    description: "Drops the session and its stored parts. Idempotent.",
    tags: ["Attachments"],
    parameters: [id: @id_param],
    responses: [no_content: "Dropped"]
  )

  def abort(conn, %{"id" => id}) do
    :ok = Uploads.abort(conn.assigns.current_user, conn.assigns.current_vault, id)
    send_resp(conn, 204, "")
  end

  defp feature(user) do
    case Billing.check_feature(user, :attachments_enabled) do
      :ok -> :ok
      {:error, :feature_not_available} -> {:error, :attachments_disabled}
    end
  end

  # Same text-only gate as the single-request path, ahead of the context so
  # it answers the upgrade 402 rather than a generic refusal.
  defp text_gate(user, %{"path" => path} = params) when is_binary(path) do
    mime = params["mime_type"]
    mime = if is_binary(mime), do: mime, else: MimeWhitelist.detect_mime(path)

    if AttachmentsController.text_only?(user) and not AttachmentsController.text_mime?(mime),
      do: {:error, :attachment_must_be_text},
      else: :ok
  end

  defp text_gate(_user, _params), do: :ok

  defp part_number(n) do
    case Integer.parse(n) do
      {n, ""} -> {:ok, n}
      _ -> {:error, :bad_part_number}
    end
  end

  # A part is never more than `part_size`, so a larger declared or actual
  # body is a bad part, refused without reading the rest.
  defp check_declared_length(conn, limit) do
    case RequestMeta.declared_length(conn) do
      n when is_integer(n) and n > limit -> {:error, :bad_part_size}
      _ -> :ok
    end
  end

  # Same bounded read as `AttachmentsController.read_raw/6`: limit + 1 so an
  # oversized body is decided by size, and `:more` within the limit is a
  # stalled client (408).
  defp read_part(conn, limit) do
    case AttachmentsController.read_raw_body(conn, limit + 1) do
      {_, body, _conn} when byte_size(body) > limit ->
        {:error, :bad_part_size}

      {:ok, body, conn} ->
        {:ok, body, conn}

      {:more, _partial, conn} ->
        {:halt,
         conn
         |> SettleUnreadBody.close_after()
         |> put_status(408)
         |> json(%{error: "request body timed out"})}

      {:error, _reason} ->
        {:halt,
         conn
         |> SettleUnreadBody.close_after()
         |> put_status(400)
         |> json(%{error: "could not read request body"})}
    end
  end

  defp refuse(conn, :attachments_disabled), do: AttachmentsController.attachments_disabled(conn)

  defp refuse(conn, :attachment_must_be_text),
    do:
      EngramWeb.LimitResponse.halt(
        conn,
        "attachment_must_be_text",
        :attachments_text_only,
        true,
        nil
      )

  defp refuse(conn, {:extension_not_allowed, ext}),
    do: conn |> put_status(415) |> json(%{error: "extension_not_allowed", extension: ext})

  defp refuse(conn, :invalid_mime),
    do: conn |> put_status(422) |> json(%{error: "invalid_mime_type"})

  defp refuse(conn, {:too_large, limit}),
    do: EngramWeb.LimitResponse.halt(conn, "file_too_large", :max_file_bytes, limit, nil)

  defp refuse(conn, {:storage_cap_reached, used, cap}),
    do:
      EngramWeb.LimitResponse.halt(
        conn,
        "attachments_quota_exceeded",
        :attachment_bytes_cap,
        cap,
        used
      )

  defp refuse(conn, :multipart_unsupported),
    do: conn |> put_status(501) |> json(%{error: "multipart_unsupported"})

  defp refuse(conn, :not_found),
    do: conn |> put_status(404) |> json(%{error: "not_found"})

  defp refuse(conn, reason) when reason in [:bad_part_number, :bad_part_size],
    do: conn |> put_status(422) |> json(%{error: Atom.to_string(reason)})

  defp refuse(conn, {:missing_parts, missing}),
    do: conn |> put_status(409) |> json(%{error: "missing_parts", missing: missing})

  defp refuse(conn, {:storage, _reason}),
    do: conn |> put_status(502) |> json(%{error: "failed to upload to storage backend"})

  # Changesets (422) and anything unforeseen go through the fallback.
  defp refuse(_conn, reason), do: {:error, reason}
end
