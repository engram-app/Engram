defmodule EngramWeb.AttachmentsController do
  use EngramWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias EngramWeb.Schemas

  alias Engram.Attachments
  alias Engram.Billing
  alias Engram.Storage.MimeWhitelist

  action_fallback EngramWeb.FallbackController

  operation(:upload,
    operation_id: "attachments-upload",
    summary: "Upload an attachment (base64 JSON)",
    description:
      "Uploads an attachment supplied as base64 JSON to the vault's storage backend. Attachments " <>
        "are a paid-tier feature (402 on Free, which is also limited to text MIME types), the MIME " <>
        "type and extension must pass the whitelist (415), the file must be within the per-plan size " <>
        "and total-quota limits (402), and a storage backend failure returns 502.",
    tags: ["Attachments"],
    request_body:
      {"Attachment bytes", "application/json", Schemas.UploadAttachmentRequest, required: true},
    responses: [
      ok: {"Uploaded", "application/json", Schemas.AttachmentResponse},
      bad_request: {"Invalid base64", "application/json", Schemas.MessageError},
      payment_required:
        {"Attachments require a paid plan / quota", "application/json", Schemas.LimitError},
      unsupported_media_type:
        {"MIME or extension not allowed", "application/json", Schemas.MimeRejected},
      unprocessable_entity: {"Missing/invalid content", "application/json", Schemas.MessageError},
      bad_gateway: {"Storage backend failure", "application/json", Schemas.MessageError}
    ]
  )

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

  # Routes through the single source of truth rather than re-deriving the
  # answer, so this gate cannot disagree with the `plan_state/1` payload the
  # plugin pre-gates on (they did disagree: see Billing.attachments_all_types?/1).
  # The 402 body still names `attachments_text_only` — that is a client-facing
  # wire identifier, not a catalog lookup, and it changes in the contract step.
  defp text_only?(user), do: not Billing.attachments_all_types?(user)

  defp text_mime?(nil), do: false

  # Same normalizer as the upload gate and `inline_safe?/1`. This was the third
  # MIME decision site and it was missed when the other two were unified, which
  # left the exact bug that unification existed to remove: a Free-tier user
  # uploading `" text/plain"` got 402 `attachment_must_be_text` while
  # `MimeWhitelist.check/2` considered the same string text.
  defp text_mime?(mime) when is_binary(mime),
    do: String.starts_with?(MimeWhitelist.normalize(mime), "text/")

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

      # Defense in depth: the context now enforces the whitelist too. The
      # pre-check above answers first on the HTTP path; these keep a context
      # rejection from falling into the changeset clause below.
      {:error, {:mime_not_allowed, mime}} ->
        conn |> put_status(415) |> json(%{error: "mime_not_allowed", mime_type: mime})

      {:error, {:extension_not_allowed, ext}} ->
        conn |> put_status(415) |> json(%{error: "extension_not_allowed", extension: ext})

      {:error, %Ecto.Changeset{}} = error ->
        error
    end
  end

  operation(:rename,
    operation_id: "attachments-rename",
    summary: "Rename / move an attachment",
    description:
      "Moves the attachment from `old_path` to `new_path`. Requires a plan with attachments " <>
        "enabled (402 otherwise). Returns 404 when the source is missing and 409 when the target " <>
        "path already exists.",
    tags: ["Attachments"],
    request_body: {"Old + new path", "application/json", Schemas.RenameRequest, required: true},
    responses: [
      ok: {"Renamed", "application/json", Schemas.AttachmentRenameResponse},
      payment_required:
        {"Attachments require a paid plan", "application/json", Schemas.LimitError},
      not_found: {"No such attachment", "application/json", Schemas.MessageError},
      conflict: {"Target exists", "application/json", Schemas.MessageError}
    ]
  )

  def rename(conn, %{"old_path" => old_path, "new_path" => new_path}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    # `attachments_enabled` is checked inside `move_attachment/4`, not here —
    # MCP's `move_attachment` tool calls that same function and was ungated
    # while the check lived in this action. The 402 rendering stays.
    case Attachments.move_attachment(user, vault, old_path, new_path) do
      {:ok, att} ->
        json(conn, %{
          renamed: true,
          old_path: old_path,
          new_path: new_path,
          attachment: serialize_metadata(att)
        })

      {:error, :feature_not_available} ->
        EngramWeb.LimitResponse.halt(
          conn,
          "attachments_disabled",
          :attachments_enabled,
          false,
          nil
        )

      {:error, reason} = error when reason in [:conflict, :not_found] ->
        error
    end
  end

  operation(:batch_move,
    operation_id: "attachments-batch-move",
    summary: "Move attachments to a folder (idempotent)",
    description:
      "Moves multiple attachments (by path) into `target_folder` and returns the moved count. " <>
        "Requires a plan with attachments enabled (402 otherwise) and the `X-Idempotency-Key` header. " <>
        "Returns 404/409 (with the offending `item_path`) if an item is missing or conflicts at the target.",
    tags: ["Attachments"],
    request_body:
      {"Paths + target folder", "application/json", Schemas.AttachmentBatchMoveRequest,
       required: true},
    responses: [
      ok: {"Moved count", "application/json", Schemas.MovedCount},
      bad_request: {"Missing params", "application/json", Schemas.MessageError},
      payment_required:
        {"Attachments require a paid plan", "application/json", Schemas.LimitError},
      not_found: {"An item was not found", "application/json", Schemas.BatchItemError},
      conflict: {"An item conflicts at target", "application/json", Schemas.BatchItemError}
    ]
  )

  def batch_move(conn, %{"paths" => paths, "target_folder" => target}) when is_list(paths) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    # Gated like rename/upload: moving attachments is "using" the feature, so a
    # plan without :attachments_enabled gets a 402 (delete stays ungated below).
    case Billing.check_feature(user, :attachments_enabled) do
      {:error, :feature_not_available} ->
        EngramWeb.LimitResponse.halt(
          conn,
          "attachments_disabled",
          :attachments_enabled,
          false,
          nil
        )

      :ok ->
        case Attachments.batch_move(user, vault, paths, target) do
          {:ok, %{moved: n}} ->
            body = %{moved: n}

            Engram.Idempotency.remember(
              conn.assigns.current_user,
              conn.assigns.idempotency_key,
              %{status: 200, body: body}
            )

            json(conn, body)

          # item_path shapes stay inline: the fallback's {:conflict, id}/
          # {:not_found, id} clauses render item_id, and these carry file
          # PATHS. Only the terminal 500 falls through.
          {:error, {:conflict, p}} ->
            conn |> put_status(409) |> json(%{error: "conflict", item_path: p})

          {:error, {:not_found, p}} ->
            conn |> put_status(404) |> json(%{error: "not_found", item_path: p})

          {:error, _} = error ->
            error
        end
    end
  end

  def batch_move(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required params: paths, target_folder"})
  end

  # Intentionally NOT billing-gated: deleting is cleanup, never trap a downgraded
  # user with attachments they can't remove. Mirrors notes-delete staying open.
  operation(:batch_delete,
    operation_id: "attachments-batch-delete",
    summary: "Delete attachments by path (idempotent)",
    description:
      "Deletes multiple attachments by path and returns the deleted count. Deliberately not " <>
        "billing-gated so a downgraded user can always clean up. Requires the `X-Idempotency-Key` " <>
        "header for safe retries.",
    tags: ["Attachments"],
    request_body:
      {"Paths", "application/json", Schemas.AttachmentBatchDeleteRequest, required: true},
    responses: [
      ok: {"Deleted count", "application/json", Schemas.DeletedCount},
      bad_request: {"Missing paths", "application/json", Schemas.MessageError}
    ]
  )

  def batch_delete(conn, %{"paths" => paths}) when is_list(paths) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault

    case Attachments.batch_delete(user, vault, paths) do
      {:ok, %{deleted: n}} ->
        body = %{deleted: n}

        Engram.Idempotency.remember(conn.assigns.current_user, conn.assigns.idempotency_key, %{
          status: 200,
          body: body
        })

        json(conn, body)

      {:error, :batch_too_large} ->
        conn |> put_status(422) |> json(%{error: "batch_too_large", max: 500})
    end
  end

  def batch_delete(conn, _params) do
    conn |> put_status(400) |> json(%{error: "missing required param: paths"})
  end

  operation(:index,
    operation_id: "attachments-index",
    summary: "List attachments (metadata only)",
    description:
      "Returns metadata (path, MIME type, size, timestamps — no bytes) for every attachment in " <>
        "the current vault. Returns 500 if the listing fails.",
    tags: ["Attachments"],
    responses: [
      ok: {"Attachments", "application/json", Schemas.AttachmentsResponse},
      internal_server_error: {"Listing failed", "application/json", Schemas.MessageError}
    ]
  )

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
                content_hash: a.content_hash,
                updated_at: a.updated_at
              }
            end)
        })

      {:error, reason} ->
        require Logger

        Logger.error(
          "Failed to list attachments",
          Engram.Logger.Metadata.with_category(:error, :sync,
            vault_id: vault.id,
            # Defensive: this branch is not currently reachable — the listing
            # is DB-only and `Repo.all` raises rather than returning `{:error,
            # _}`. Rendered as a label anyway so it cannot become a leak if a
            # storage call is ever added here. The `noqa` this replaced claimed
            # a "bounded ExAws error term"; there is no ExAws call on this path
            # at all, so the note was wrong in both directions.
            reason: Engram.Logger.Metadata.safe_reason(reason)
          )
        )

        conn |> put_status(500) |> json(%{error: "failed to list attachments"})
    end
  end

  operation(:show,
    operation_id: "attachments-show",
    summary: "Get an attachment",
    tags: ["Attachments"],
    description:
      "Returns metadata + base64 content by default. Pass `?raw=1` to stream the raw bytes instead.",
    parameters: [
      path: [in: :path, type: :string, required: true, description: "Attachment path"],
      raw: [
        in: :query,
        type: :string,
        required: false,
        description: "\"1\" streams raw bytes instead of JSON."
      ]
    ],
    responses: [
      ok: {"Attachment", "application/json", Schemas.AttachmentWithContent},
      not_found: {"No such attachment", "application/json", Schemas.MessageError},
      bad_gateway: {"Storage fetch failed", "application/json", Schemas.MessageError},
      internal_server_error: {"Fetch error", "application/json", Schemas.MessageError}
    ]
  )

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
          |> maybe_skip_compression(att.mime_type)
          |> send_resp(200, att.content)
        else
          json(conn, %{
            id: att.id,
            path: att.path,
            mime_type: att.mime_type,
            size_bytes: att.size_bytes,
            mtime: att.mtime,
            content_hash: att.content_hash,
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

  operation(:delete,
    operation_id: "attachments-delete",
    summary: "Delete an attachment",
    description:
      "Deletes the attachment at the given path. Idempotent — always returns `deleted: true` " <>
        "with the path, and is not billing-gated so downgraded users can still remove files.",
    tags: ["Attachments"],
    parameters: [path: [in: :path, type: :string, required: true, description: "Attachment path"]],
    responses: [ok: {"Deleted", "application/json", Schemas.AttachmentDeleted}]
  )

  def delete(conn, %{"path" => path_parts}) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    path = Path.join(path_parts)

    Attachments.delete_attachment(user, vault, path,
      origin_device_id: EngramWeb.OriginDevice.from_conn(conn)
    )

    json(conn, %{deleted: true, path: path})
  end

  operation(:changes,
    operation_id: "attachments-changes",
    summary: "Retired timestamp change feed",
    deprecated: true,
    description:
      "Retired. The timestamp-based attachment change feed has been removed; this endpoint " <>
        "always returns 410 Gone. Clients sync via the CRDT sync socket and `GET /sync/manifest` " <>
        "(current plugin versions already do).",
    tags: ["Attachments"],
    responses: [
      gone: {"Feed retired", "application/json", Schemas.Error}
    ]
  )

  # Retired timestamp feed (zero authenticated prod traffic). The route stays
  # so old clients get an explicit 410 instead of a generic 404.
  def changes(conn, _params) do
    conn
    |> put_status(410)
    |> json(%{
      error: "gone",
      message:
        "The timestamp change feed was removed. Sync via the CRDT sync socket and " <>
          "/sync/manifest (current plugin versions already do)."
    })
  end

  # Types safe to render inline in the browser on the API origin. Raster images
  # and PDFs are inert; SVG (script via <script>) and HTML/XML (script via
  # markup or XSLT) are NOT — they force-download. Everything not on this list
  # downloads by default.
  defp inline_safe?(nil), do: false

  defp inline_safe?(mime) when is_binary(mime) do
    # Normalize BEFORE matching. `mime_type` is stored verbatim from the
    # uploader (see create/2), so the bare `"image/svg+xml"` clause this used
    # to match on was trivially sidestepped: `image/svg+xml; charset=utf-8`
    # and `image/svg+xml ` both missed the exclusion and fell into the
    # `starts_with?("image/")` allowlist, i.e. an SVG (a script-executing
    # document format) served `inline`.
    #
    # Shared with `MimeWhitelist.check/2` on purpose: the upload gate and this
    # serve gate must agree on what a value MEANS, or the same media type gets
    # opposite answers depending on whitespace. Normalizing here only, as an
    # earlier version of this fix did, was how that split appeared.
    case MimeWhitelist.normalize(mime) do
      "image/svg+xml" -> false
      "application/pdf" -> true
      "text/plain" -> true
      type -> String.starts_with?(type, "image/")
    end
  end

  # Bandit compresses ANY response body when the client sends `Accept-Encoding:
  # gzip`: `Bandit.Compression.negotiate_content_encoding/2` defaults `compress`
  # to true, and `new/5` applies NO content-type check. So a PNG, PDF or video
  # gets deflated on the way out — CPU spent to produce a payload that is
  # usually LARGER than the input. A 2026-08-21 prod profile put
  # `:zlib.append_iolist/2` at 8.57s, 5.79% of all CPU, reached straight from
  # this controller's `action/2`.
  #
  # `cache-control: no-transform` is the one opt-out Bandit honours
  # (`response_indicates_no_transform/1`) that is also semantically correct:
  # RFC 9111 no-transform tells intermediaries not to re-encode the payload,
  # which is exactly the claim being made. The alternatives are worse — a
  # `content-encoding: identity` header is not valid in a response per RFC 9110
  # (identity is an Accept-Encoding-only token), and faking a strong ETag to
  # suppress compression would be a lie about the representation.
  #
  # APPEND, never replace. Phoenix already sets `cache-control: max-age=0,
  # private, must-revalidate` on these responses, so a `put_resp_header/3` with
  # a bare `no-transform` silently drops `private` — quietly making attachment
  # bytes shared-cacheable as a side effect of a CPU fix, which is exactly the
  # class of accident docs/context/edge-cache-request-varying-headers.md is
  # about. Bandit only needs the token present in the list, not alone.
  @doc false
  @spec no_transform_directive() :: String.t()
  def no_transform_directive, do: "no-transform"

  # Types whose bytes are already entropy-coded. Note the exclusions:
  # `image/svg+xml` is XML, `image/bmp` and `image/tiff` are commonly stored
  # uncompressed, and `application/octet-stream` says nothing about the
  # payload — all keep gzip.
  #
  # Deliberately an allow-list, not a deny-list: an unrecognised type keeps
  # compressing, so a stale list costs a little CPU rather than shipping a
  # large payload uncompressed.
  @precompressed_exact MapSet.new(~w(
    application/pdf application/zip application/gzip application/x-gzip
    application/x-7z-compressed application/x-rar-compressed application/x-bzip2
    application/vnd.rar application/epub+zip
    font/woff font/woff2
  ))

  @precompressed_prefixes ~w(video/ audio/)

  @doc false
  @spec precompressed?(String.t() | nil) :: boolean()
  def precompressed?(mime) do
    # Same normalizer as the upload gate and `inline_safe?/1`: a media type
    # must not mean different things to different gates just because it
    # carries a parameter or odd casing.
    case MimeWhitelist.normalize(mime) do
      nil -> false
      "image/svg+xml" -> false
      "image/bmp" -> false
      "image/tiff" -> false
      type -> precompressed_type?(type)
    end
  end

  defp precompressed_type?(type) do
    String.starts_with?(type, "image/") or
      Enum.any?(@precompressed_prefixes, &String.starts_with?(type, &1)) or
      MapSet.member?(@precompressed_exact, type)
  end

  defp maybe_skip_compression(conn, mime) do
    if precompressed?(mime), do: append_no_transform(conn), else: conn
  end

  defp append_no_transform(conn) do
    case get_resp_header(conn, "cache-control") do
      [] ->
        put_resp_header(conn, "cache-control", no_transform_directive())

      [existing | _] ->
        if no_transform_directive() in Plug.Conn.Utils.list(existing) do
          conn
        else
          put_resp_header(conn, "cache-control", existing <> ", " <> no_transform_directive())
        end
    end
  end

  # `content_hash` is a keyed HMAC over the plaintext, scoped to this user's
  # own DEK — it is not derivable by anyone else and tells its owner exactly
  # one thing: whether the bytes they hold are the bytes we hold. Exposing it
  # is what lets a client stop re-sending attachments the server already has
  # (see Engram.Attachments.identical_or_changed/4).
  defp serialize_metadata(att) do
    %{
      id: att.id,
      path: att.path,
      mime_type: att.mime_type,
      size_bytes: att.size_bytes,
      mtime: att.mtime,
      content_hash: att.content_hash,
      created_at: att.created_at,
      updated_at: att.updated_at
    }
  end
end
