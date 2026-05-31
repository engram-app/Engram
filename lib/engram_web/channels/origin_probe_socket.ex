defmodule EngramWeb.OriginProbeSocket do
  @moduledoc """
  No-auth socket used by the post-deploy WebSocket smoke
  (engram-infra `ops/post-apply-smoke/ws.sh`). `connect/3` always returns
  `{:ok, socket}` and no channels are attached, so the only gate is
  `Phoenix.Socket.check_origin` — the smoke can distinguish origin-allowed
  (101 Switching Protocols) from origin-rejected (403) at the HTTP layer
  without minting an auth token.

  The main `/socket` (EngramWeb.UserSocket) requires a `"token"` param and
  returns 403 on its absence, which is indistinguishable from a
  `check_origin` 403 — that's why this dedicated probe socket exists
  rather than smoking the main socket.

  Security: an attacker that opens this socket can do nothing with it (no
  channels to join, no messages to send). It exists purely as a probe for
  the origin allowlist.
  """
  use Phoenix.Socket

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
