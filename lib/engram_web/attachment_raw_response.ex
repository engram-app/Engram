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


  Format v2 content (`{:segments, stream}`) goes out chunked, one segment at
  a time, with `status` (206 for a range). Headers are sent before the first
  segment is opened, so a segment that fails to open cannot change the
  status: the response is aborted instead (`StreamAborted`), which makes
  the server drop the connection. Returning normally would let the adapter
  finish the body, and the client would hold a truncated file that looks
  complete.
  """

  import Plug.Conn

  defmodule StreamAborted do
    @moduledoc false
    # The cause (attachment id, segment) is logged where it is detected,
    # `Engram.Attachments.segment_stream/4`; this message carries none of it.
    defexception message: "attachment body aborted mid-stream: segment unreadable"
  end

  @spec send(Plug.Conn.t(), Engram.Attachments.Attachment.t(), boolean(), Plug.Conn.status()) ::
          Plug.Conn.t()
  def send(conn, att, inline?, status \\ 200) do
    disposition = if inline?, do: "inline", else: "attachment"
    # Strip control chars/quotes so a crafted filename can't break the header
    # (Plug rejects control chars → 500 otherwise).
    filename = String.replace(Path.basename(att.path), ~r/[[:cntrl:]"]/u, "")

    conn
    |> put_resp_content_type(att.mime_type || "application/octet-stream")
    |> put_resp_header("content-disposition", ~s(#{disposition}; filename="#{filename}"))
    |> send_body(status, att.content)
  end

  defp send_body(conn, _status, bytes) when is_binary(bytes), do: send_resp(conn, 200, bytes)

  defp send_body(conn, status, {:segments, stream}) do
    Enum.reduce_while(stream, send_chunked(conn, status), fn
      {:ok, bytes}, conn ->
        case chunk(conn, bytes) do
          {:ok, conn} -> {:cont, conn}
          # The client went away; nothing left to send to.
          {:error, _} -> {:halt, conn}
        end

      {:error, _}, _conn ->
        raise StreamAborted
    end)
  end
end
