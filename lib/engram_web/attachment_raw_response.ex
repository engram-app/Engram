defmodule EngramWeb.AttachmentRawResponse do
  @moduledoc """
  Sends an attachment's raw bytes (`GET /api/attachments/*path?raw=1`).

  Its own small module so the two sobelow-pinned calls (`XSS.ContentType`,
  `XSS.SendResp`) live in a file that rarely changes: pinned in the busy
  controller, every unrelated edit above them shifted the fingerprint and
  failed lint (see docs/context/sobelow-silent-no-op-and-fingerprint-skips.md).

  Why the pins are safe: bytes are served from the API origin with nosniff (the
  `:api` pipeline), and only types the caller proved inert render inline. HTML,
  SVG and XML can execute script, and the MIME whitelist admits all of `text/`,
  so everything not inline-safe force-downloads.
  """

  import Plug.Conn

  @spec send(Plug.Conn.t(), Engram.Attachments.Attachment.t(), boolean()) :: Plug.Conn.t()
  def send(conn, att, inline?) do
    disposition = if inline?, do: "inline", else: "attachment"
    # Strip control chars/quotes so a crafted filename can't break the header
    # (Plug rejects control chars → 500 otherwise).
    filename = String.replace(Path.basename(att.path), ~r/[[:cntrl:]"]/u, "")

    conn
    |> put_resp_content_type(att.mime_type || "application/octet-stream")
    |> put_resp_header("content-disposition", ~s(#{disposition}; filename="#{filename}"))
    |> send_resp(200, att.content)
  end
end
