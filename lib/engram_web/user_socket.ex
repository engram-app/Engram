defmodule EngramWeb.UserSocket do
  use Phoenix.Socket

  alias Engram.Crypto.HMAC
  alias Engram.Logger.Metadata

  require Logger

  channel "sync:*", EngramWeb.SyncChannel
  channel "crdt:*", EngramWeb.CrdtChannel
  channel "user:*", EngramWeb.UserChannel

  @impl true
  def connect(%{"token" => token} = params, socket, _connect_info) do
    case Engram.Auth.TokenResolver.resolve(token) do
      {:ok, user} ->
        {:ok, accept(socket, user, nil, token, params)}

      {:ok, user, :internal_jwt} ->
        # Device-flow / OAuth / MCP access tokens. Mirror the Auth plug's
        # branch — current_api_key stays nil so downstream code that
        # branches on its presence (e.g. SyncChannel api-key vault
        # restriction) doesn't misclassify this as a PAT auth and try to
        # treat the atom `:internal_jwt` as a struct.
        {:ok, accept(socket, user, nil, token, params)}

      {:ok, user, api_key} ->
        {:ok, accept(socket, user, api_key, token, params)}

      {:error, reason} ->
        # Previously silent — during a Clerk break every SPA reconnect storms
        # this path with no log and no metric. Mirror the HTTP plug.
        label = Engram.Auth.emit_rejected(reason, :socket)

        Logger.warning(
          "auth rejected",
          Metadata.with_category(
            :warning,
            :auth,
            [reason: label] ++ Engram.Auth.TokenDebug.metadata(token)
          )
        )

        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # Stamps connection-correlation ids into assigns and logs the connect. The
  # ids are client-supplied (URL query params); conn_id is unique per physical
  # socket, device_id is stable per install. Both are echoed on every channel
  # lifecycle log so a plugin log line and a backend log line for the same
  # socket share a key.
  defp accept(socket, user, api_key, token, params) do
    conn_id = params["conn_id"]
    device_id = params["device_id"]
    vault_id = params["vault_id"]

    Logger.info(
      "ws connect",
      Metadata.with_category(:info, :websocket,
        conn_id: conn_id,
        device_id: device_id,
        vault_id: vault_id,
        user_id: HMAC.hash_user_id(to_string(user.id))
      )
    )

    assign(socket, %{
      current_user: user,
      current_api_key: api_key,
      oauth_scope_vault_ids: oauth_scope_vault_ids(token),
      conn_id: conn_id,
      device_id: device_id,
      vault_id_param: vault_id
    })
  end

  # Same claims OAuthScopeEnforce surfaces for HTTP. Plugs do not run for a
  # socket connect, so without this the channels have no OAuth scope to enforce
  # and a vault-scoped token joins any vault's topic.
  #
  # Re-parsed rather than threaded out of TokenResolver: `resolve/1` is shared
  # with the HTTP Auth plug, and widening its return shape for one caller is a
  # bigger blast radius than a local re-parse. This is a second HS256 verify per
  # CONNECTION, not per message — the same trade OAuthScopeEnforce already makes
  # per request.
  #
  # Deliberately not restricted to the resolver's `:internal_jwt` branch: under
  # the `:local` provider (self-host) an OAuth access token verifies as an
  # ordinary provider JWT and resolves through `{:ok, user}`, so branching on the
  # tag would leave self-host unenforced. `verify_jwt/1` fails for API keys and
  # Clerk RS256 tokens, and any token with no grant claims yields nil, which
  # `Permissions` reads as unrestricted.
  defp oauth_scope_vault_ids(token) do
    case Engram.Accounts.verify_jwt(token) do
      {:ok, claims} -> Engram.Permissions.scope_ids_from_claims(claims)
      _ -> nil
    end
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"
end
