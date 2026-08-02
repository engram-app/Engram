defmodule EngramWeb.OAuthRegisterController do
  @moduledoc """
  RFC 7591 Dynamic Client Registration. Public, rate-limited.

  Mints public PKCE clients by default, `token_endpoint_auth_method=none`
  with no `client_secret`. A client that asks for `client_secret_post` or
  `client_secret_basic` is minted a secret, returned once in the 201 and
  stored only as a hash. PKCE is required either way.
  """
  use EngramWeb, :controller

  alias Engram.Connections.LogoAllowlist
  alias Engram.Logger.Metadata
  alias Engram.OAuth
  alias EngramWeb.RequestMeta

  require Logger

  @telemetry_event [:engram, :mcp, :dcr, :register]

  def register(conn, params) do
    enriched =
      params
      |> Map.put("first_user_agent", RequestMeta.get_user_agent(conn))
      |> Map.put("first_ip", RequestMeta.format_ip(conn.remote_ip))

    case OAuth.register_client(enriched) do
      {:ok, client} ->
        emit_telemetry(:ok, client.client_id, client.software_id, client.kind)
        log_unattributed(client)

        conn
        |> put_status(:created)
        |> json(serialize(client))

      {:error, changeset} ->
        emit_telemetry(
          :error,
          nil,
          Ecto.Changeset.get_field(changeset, :software_id),
          Ecto.Changeset.get_field(changeset, :kind)
        )

        {error, description} = changeset_error(changeset)
        log_rejected(changeset, description)

        conn
        |> put_status(:bad_request)
        |> json(%{error: error, error_description: description})
    end
  end

  # A rejected registration is a connector that cannot connect AT ALL, and the
  # only record of why lives in this request. Telemetry alone carries no
  # `token_endpoint_auth_method`, so a client asking for a confidential
  # registration (which we do not mint) failed silently from our side while the
  # vendor surfaced our error as their own 500. Log enough to identify the
  # client and the metadata it wanted.
  #
  # `:lifecycle` because `:auth` info does not ship to Loki (see
  # Engram.Logger.Category). Name is normalized, so no user-chosen suffix leaks.
  defp log_rejected(changeset, description) do
    Logger.warning(
      "mcp_dcr_rejected",
      Metadata.with_category(:warning, :lifecycle,
        normalized_name:
          changeset |> Ecto.Changeset.get_field(:client_name) |> LogoAllowlist.normalize_name(),
        requested_auth_method: Ecto.Changeset.get_field(changeset, :token_endpoint_auth_method),
        software_id: Ecto.Changeset.get_field(changeset, :software_id),
        reason: description
      )
    )
  end

  # The DCR body is the only place a client's self-reported identity exists;
  # no vendor publishes these strings. When one resolves to no slug, its
  # onboarding checklist row cannot tick, so record the normalized name and let
  # prod tell us what to add to `@name_aliases` instead of guessing.
  #
  # Everything logged here is deliberately de-identified:
  #
  #   * the NORMALIZED name, which drops the user-chosen server suffix
  #     ("Claude Code (my-private-project)"), and
  #   * scheme + host only, never the full redirect. A self-hosted client
  #     redirects to the operator's own domain with a path that can carry
  #     instance detail, and RequestLogger already redacts request paths, so
  #     shipping whole URIs here would undercut that. Scheme + host is all the
  #     classification (vendor / loopback / self-hosted) actually needs.
  defp log_unattributed(%{kind: "mcp"} = client) do
    if not attributed?(client) do
      Logger.info(
        "mcp_dcr_unattributed_client",
        Metadata.with_category(:info, :lifecycle,
          normalized_name: LogoAllowlist.normalize_name(client.client_name),
          redirect_origins: redirect_origins(client.redirect_uris),
          software_id: client.software_id
        )
      )
    end
  end

  defp log_unattributed(_), do: :ok

  # `resolve/4` takes the ONE redirect a grant used, because verifying against a
  # registered list is #1204. Registration has no grant yet, so this tripwire is
  # the one place an any-match is right: the question is only "will this client
  # ever attribute", and the answer is yes if any redirect it registered would.
  # `nil` covers the software_id / client_name paths, which need no redirect.
  #
  # Only `slug` is read. Nothing here can grant a badge — that is decided per
  # grant in `Engram.Connections`, from the redirect actually used.
  defp attributed?(client) do
    Enum.any?([nil | client.redirect_uris || []], fn uri ->
      LogoAllowlist.resolve(client.software_id, uri, client.client_name).slug != nil
    end)
  end

  defp redirect_origins(uris) when is_list(uris) do
    Enum.map(uris, fn uri ->
      case URI.new(uri) do
        {:ok, %URI{scheme: scheme, host: host}} -> "#{scheme}://#{host}"
        _ -> "unparseable"
      end
    end)
  end

  defp redirect_origins(_), do: []

  defp emit_telemetry(result, client_id, software_id, kind) do
    :telemetry.execute(@telemetry_event, %{count: 1}, %{
      result: result,
      client_id: client_id,
      software_id: software_id,
      kind: kind
    })
  end

  defp serialize(client) do
    %{
      client_id: client.client_id,
      client_id_issued_at: DateTime.to_unix(client.inserted_at),
      redirect_uris: client.redirect_uris,
      client_name: client.client_name,
      scope: client.scope,
      grant_types: client.grant_types,
      response_types: client.response_types,
      token_endpoint_auth_method: client.token_endpoint_auth_method,
      client_secret: client.client_secret,
      # RFC 7591 §3.2.1: REQUIRED whenever a client_secret is issued. 0 means
      # the secret does not expire. Map.reject below drops it for public
      # clients, where there is no secret to describe.
      client_secret_expires_at: client.client_secret && 0,
      software_id: client.software_id,
      software_version: client.software_version,
      logo_uri: client.logo_uri,
      tos_uri: client.tos_uri,
      policy_uri: client.policy_uri
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp changeset_error(changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, &translate_error/1)

    if Map.has_key?(errors, :redirect_uris) do
      {"invalid_redirect_uri", join_errors(errors[:redirect_uris])}
    else
      {"invalid_client_metadata", flat_describe(errors)}
    end
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      placeholder = "%{#{key}}"

      # Only stringify when the placeholder is actually present. A failed cast
      # (e.g. a JSON string where an array is expected) carries opts like
      # `type: {:array, :string}` whose message ("is invalid") has no
      # placeholder, eagerly to_string-ing that tuple is what crashed (500).
      if String.contains?(acc, placeholder) do
        String.replace(acc, placeholder, to_string(value))
      else
        acc
      end
    end)
  end

  defp join_errors(list) when is_list(list), do: Enum.join(list, "; ")
  defp join_errors(other), do: to_string(other)

  defp flat_describe(errors) when is_map(errors) do
    Enum.map_join(errors, "; ", fn {field, msgs} -> "#{field}: #{join_errors(msgs)}" end)
  end
end
