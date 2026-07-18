defmodule EngramWeb.OriginDevice do
  @moduledoc """
  Extracts the caller's opaque device identity from the `X-Device-Id` request
  header (#970). The Obsidian plugin sends it on every REST call; stamping it
  into `note_changed` broadcasts lets the originating device drop its own
  fanout echo — REST-driven changes have no socket pid for `broadcast_from`
  exclusion, which is how the 2026-07-08 replace-remote wipe applied its own
  delete echoes and trashed the local vault.

  The value is client-generated and treated as opaque: printable/valid UTF-8,
  length-capped, never trusted for authorization — it only ever routes an
  echo-drop on the client that already made the request.

  Known limitation (accepted): the header is not bound to the authenticated
  session, so a same-account client can spoof another device's id and make
  that device drop a delete echo. That is strictly weaker than the API power
  the caller already holds (it can delete anything outright), and the next
  cursor pull reconciles unedited files. Binding device identity to the
  session/connection is the remaining #970 work.
  """

  @max_bytes 64

  @spec from_conn(Plug.Conn.t()) :: String.t() | nil
  def from_conn(conn) do
    case Plug.Conn.get_req_header(conn, "x-device-id") do
      [id | _] when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_bytes ->
        if String.valid?(id), do: id, else: nil

      _ ->
        nil
    end
  end
end
