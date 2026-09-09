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
      oauth_scope_vault_ids: oauth_scope_vault_ids(token),
      conn_id: conn_id,
      device_id: device_id,
      vault_id_param: vault_id,
      plugin_version: plugin_version
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
  #
  # ponytail: re-verify can disagree with resolve/1 across an exp boundary;
  # fail-open by microseconds. Thread claims out of resolve/1 if that ever
  # matters. (A token in its final second can pass resolve/1 and then fail
  # here, yielding nil -> :all, so a vault-scoped socket would connect
  # unrestricted for its lifetime.)
  defp oauth_scope_vault_ids(token) do
    case Engram.Accounts.verify_jwt(token) do
      {:ok, claims} -> Engram.Permissions.scope_ids_from_claims(claims)
      _ -> nil
    end
  end

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
