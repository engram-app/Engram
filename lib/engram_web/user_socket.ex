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
    resolve_and_accept(token, params, socket)
  end

  def connect(_params, _socket, _connect_info), do: :error

  # `:rest`: an MCP OAuth token has no business on the sync socket.
  defp resolve_and_accept(token, params, socket) do
    case Engram.Auth.TokenResolver.resolve(token, :rest) do
      {:ok, user} ->
        # See `read_claims/1` for why this branch reads grant claims too
        # (self-host only: a Clerk JWT never carries a grant).
        case provider_claims(token) do
          {:ok, claims} -> {:ok, accept(socket, user, nil, claims, params)}
          :error -> {:ok, accept(socket, user, nil, nil, params)}
          :revoked -> reject(:grant_revoked, token)
        end

      {:ok, user, :internal_jwt} ->
        # Device-flow / OAuth / MCP access tokens. Mirror the Auth plug's
        # branch — current_api_key stays nil so downstream code that
        # branches on its presence (e.g. SyncChannel api-key vault
        # restriction) doesn't misclassify this as a PAT auth and try to
        # treat the atom `:internal_jwt` as a struct. One of OUR tokens whose
        # claims cannot be read is refused: an unreadable grant is never
        # "no restriction".
        case read_claims(token) do
          {:ok, claims} -> {:ok, accept(socket, user, nil, claims, params)}
          :revoked -> reject(:grant_revoked, token)
          :error -> :error
        end

      {:ok, user, api_key} ->
        # A raw API key is not a JWT: it carries no grant claims.
        {:ok, accept(socket, user, api_key, nil, params)}

      {:error, reason} ->
        # Previously silent — during a Clerk break every SPA reconnect storms
        # this path with no log and no metric. Mirror the HTTP plug.
        reject(reason, token)
    end
  end

  # One log line and one `[:engram, :auth, :rejected]` event per refused
  # connect, as `Plugs.Auth` does for HTTP, a revoked grant included.
  defp reject(reason, token) do
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

  defp provider_claims(token) do
    if Engram.Auth.provider_tokens_carry_grants?(), do: read_claims(token), else: :error
  end

  # Stamps connection-correlation ids into assigns and logs the connect. The
  # ids are client-supplied (URL query params); conn_id is unique per physical
  # socket, device_id is stable per install. Both are echoed on every channel
  # lifecycle log so a plugin log line and a backend log line for the same
  # socket share a key.
  defp accept(socket, user, api_key, claims, params) do
    conn_id = params["conn_id"]
    device_id = params["device_id"]
    vault_id = params["vault_id"]
    # BOUNDED, because this is an attacker-controlled query param that lands in
    # Logger metadata, and prod serializes all metadata. Unbounded, any holder
    # of a valid token could push ~10KB (Bandit's request-line cap) per connect
    # into a long-retention aggregator. Two in-repo precedents bound the same
    # kind of value: `request_logger.ex` truncates `user_agent` to 200 for this
    # exact reason, and `logs.ex` bounds `plugin_version` to 128 on the
    # client-log ingest path. 32 is `PluginVersion`'s own bound and holds every
    # version this repo can emit with room to spare. See `bounded_version/1`
    # for why it DROPS rather than truncates.
    plugin_version = bounded_version(params["plugin_version"])

    # `plugin_version` is logged HERE and nowhere else. It is the evidence you
    # read before raising `Engram.PluginVersion.minimum/0`, and this is the one
    # place where that costs a field per SOCKET rather than a field per request
    # — the version distribution of everything that syncs, at ~1 line per
    # client per reconnect. Do not also add it to `RequestLogger`; see the
    # ingest-cost note there.
    #
    # Read it in CLOUDWATCH (`/ecs/engram-saas-prod`), not Loki. This is an
    # `:info` + `:websocket` line, and while `Logger.Category` lists
    # `:websocket` in `@info_to_loki`, the Fluent Bit category regex does not
    # — so info websocket lines reach CloudWatch and NOT Loki. That mismatch is
    # deliberate and pre-existing (see the NOTE in `category.ex`); do not
    # widen the routing rule to make this queryable in Grafana without first
    # deciding the volume.
    Logger.info(
      "ws connect",
      Metadata.with_category(:info, :websocket,
        conn_id: conn_id,
        device_id: device_id,
        vault_id: vault_id,
        plugin_version: plugin_version,
        user_id: HMAC.hash_user_id(to_string(user.id))
      )
    )

    assign(socket, %{
      current_user: user,
      current_api_key: api_key,
      oauth_scope_vault_ids: claims && Engram.Permissions.scope_ids_from_claims(claims),
      oauth_access: claims && Engram.Permissions.from_claims(claims),
      # Kept so a `crdt:` join can re-resolve the grant (`gid`): a grant
      # revoked or narrowed after connect must not keep joining.
      oauth_claims: claims,
      conn_id: conn_id,
      device_id: device_id,
      vault_id_param: vault_id,
      plugin_version: plugin_version
    })
  end

  # The grant claims OAuthScopeEnforce surfaces for HTTP, read ONCE per
  # connect. Plugs do not run for a socket connect, so without this the
  # channels have no OAuth scope to enforce and a vault-scoped token joins any
  # vault's topic.
  #
  # Re-read rather than threaded out of TokenResolver: `resolve/1` is shared
  # with the HTTP Auth plug, and widening its return shape for one caller is a
  # bigger blast radius than a local re-read. `grant_claims/1` checks the
  # signature but not `exp` (the resolver just validated it in full), so a
  # token in its final second cannot pass resolve/1 and then read here as
  # claim-less, i.e. unrestricted for the socket's lifetime.
  #
  # Also read on the resolver's plain `{:ok, user}` branch: under the `:local`
  # provider (self-host) an OAuth access token verifies as an ordinary
  # provider JWT and resolves there, so reading only on `:internal_jwt` would
  # leave self-host unenforced. A token with no grant claims (a session JWT)
  # yields nil, which `Permissions` reads as unrestricted.
  @doc false
  @spec read_claims(String.t()) :: {:ok, map()} | :error | :revoked
  def read_claims(token), do: Engram.Accounts.grant_claims(token)

  # Every socket write rides the crdt: channel, which refuses a read-level
  # vault at join (#174, #332), so a read-only credential may still connect:
  # sync: and user: accept no inbound writes and are how it hears about
  # changes.

  # DROP an over-long value; do not truncate it. Two bugs live in the obvious
  # `String.slice(v, 0, 32)`:
  #
  #   * `String.slice/3` counts GRAPHEMES, and a grapheme cluster is unbounded
  #     in bytes. `"e" <> String.duplicate(<combining acute>, 3000)` is ONE
  #     grapheme, so the "32-byte" clamp returned 6KB — the exact ingest cost
  #     this function exists to prevent.
  #   * Truncating CHANGES THE VERDICT. `PluginVersion.supported?/1` refuses to
  #     parse anything over 32 bytes and therefore allows it. Truncate first
  #     and a 40-byte `"1.0.0-" <> 34 a's` becomes a parseable `1.0.0`, which
  #     is below the floor — so the same client got 200 on REST (raw header)
  #     and `plugin_upgrade_required` on a channel join (clamped param). The
  #     gate must see what the CLIENT sent, on both transports.
  #
  # Dropping is verdict-identical to passing the raw value through — both end
  # at `supported?(_) -> true` — and bounds the log. Non-binaries
  # (`?plugin_version[]=x` decodes to a list) go the same way, which also keeps
  # the assign honest against its `String.t() | nil` spec.
  defp bounded_version(v) when is_binary(v) and byte_size(v) <= 32, do: v
  defp bounded_version(_), do: nil

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"
end
