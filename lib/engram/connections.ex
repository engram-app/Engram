defmodule Engram.Connections do
  @moduledoc """
  Unified view of credentials a user has granted: OAuth refresh tokens
  (joined to oauth_clients), device refresh tokens (plugin device flow),
  and api_keys. See docs/superpowers/specs/2026-05-30-connections-page-design.md.

  ## Revoke routing

  The same `client_id` JSON field carries different identifiers per kind:
    * `:obsidian` (device-flow) — `client_id = family_id` (UUID), revoke via
      `DELETE /api/connections/device/:family_id`
    * `:mcp`, `:obsidian` (OAuth) — `client_id = oauth_clients.client_id`,
      revoke via `DELETE /api/connections/oauth/:client_id`
    * `:pat` — `key_id` (integer), revoke via `DELETE /api/connections/pat/:id`

  Frontend consumers must branch on `kind` to choose the right route.
  """

  import Ecto.Query
  alias Engram.Accounts.{ApiKey, User}
  alias Engram.Auth.DeviceRefreshToken
  alias Engram.Connections.LogoAllowlist
  alias Engram.OAuth.{Client, RefreshToken}
  alias Engram.Repo
  alias Engram.Vaults

  @type kind :: :obsidian | :mcp

  @doc """
  Returns the count of distinct active connections of `kind` for `user_id`.

  For `:obsidian`, counts BOTH OAuth refresh-token families (joined to
  oauth_clients with kind="obsidian") AND device_refresh_token families, so
  the cap is honest across both auth paths the plugin can use.

  For `:mcp`, counts only OAuth families (MCP clients use DCR, not device
  flow).

  "Active" means: not revoked, not consumed (OAuth), not expired.
  Multiple tokens in the same rotation family collapse to 1 (DISTINCT).
  """
  @spec count_active(Ecto.UUID.t(), kind()) :: non_neg_integer()
  def count_active(user_id, :obsidian) do
    oauth_active_count(user_id, "obsidian") + device_active_count(user_id)
  end

  def count_active(user_id, :mcp) do
    oauth_active_count(user_id, "mcp")
  end

  defp oauth_active_count(user_id, kind_str) do
    from(t in RefreshToken,
      join: c in Client,
      on: c.client_id == t.client_id,
      where: t.user_id == ^user_id,
      where: c.kind == ^kind_str,
      where: is_nil(t.revoked_at),
      where: is_nil(t.consumed_at),
      select: count(fragment("DISTINCT ?", t.client_id))
    )
    |> Repo.one()
  end

  defp device_active_count(user_id) do
    from(rt in DeviceRefreshToken,
      where: rt.user_id == ^user_id,
      where: is_nil(rt.revoked_at),
      where: rt.expires_at > ^DateTime.utc_now(),
      select: count(fragment("DISTINCT ?", rt.family_id))
    )
    |> Repo.one()
  end

  @doc """
  Returns the most recent `revoked_at` timestamp across the user's device
  refresh tokens, or `nil` if no device family has ever been revoked.

  Used by `EngramWeb.Plugs.EnforceDeviceCap` to detect whether a Free user
  is inside the `device_swap_cooldown_hours` window after revoking a
  device. Family-grain (not row-grain): one revoke per swap.
  """
  @spec most_recent_device_revoke(Ecto.UUID.t()) :: DateTime.t() | nil
  def most_recent_device_revoke(user_id) do
    from(rt in DeviceRefreshToken,
      where: rt.user_id == ^user_id,
      where: not is_nil(rt.revoked_at),
      select: max(rt.revoked_at)
    )
    |> Repo.one()
  end

  @doc """
  Revokes (sets `revoked_at = now`) all active refresh tokens for `(user_id, client_id, vault_id)`.

  When `vault_id` is `nil`, ALL vault scopes for that user+client are revoked —
  this is the device-flow case where the original grant had no vault binding.
  Vault-scoped controllers MUST pass the originating `vault_id` to avoid
  inadvertent cross-vault revocation.

  Idempotent: a second call after revoke returns `:ok`. Unknown user+client
  combinations return `{:error, :not_found}`.
  """
  @spec revoke_oauth_family(integer(), String.t(), integer() | nil) ::
          :ok | {:error, :not_found}
  def revoke_oauth_family(user_id, client_id, vault_id) do
    now = DateTime.utc_now(:second)

    query =
      from(t in RefreshToken,
        where: t.user_id == ^user_id,
        where: t.client_id == ^client_id,
        where: is_nil(t.revoked_at)
      )

    query =
      if vault_id do
        from(t in query, where: t.vault_id == ^vault_id)
      else
        query
      end

    case Repo.update_all(query, set: [revoked_at: now]) do
      {0, _} -> if any_history?(user_id, client_id), do: :ok, else: {:error, :not_found}
      {_, _} -> :ok
    end
  end

  @doc """
  Revokes (sets `revoked_at = now`) all active device refresh tokens for
  `(user_id, family_id)`.

  Idempotent: a second call after all tokens are already revoked returns `:ok`.
  Unknown `(user_id, family_id)` combinations return `{:error, :not_found}`.
  """
  @spec revoke_device_family(integer(), Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def revoke_device_family(user_id, family_id) do
    now = DateTime.utc_now(:second)

    query =
      from(rt in DeviceRefreshToken,
        where: rt.user_id == ^user_id,
        where: rt.family_id == ^family_id,
        where: is_nil(rt.revoked_at)
      )

    case Repo.update_all(query, set: [revoked_at: now]) do
      {0, _} -> if device_history?(user_id, family_id), do: :ok, else: {:error, :not_found}
      {_, _} -> :ok
    end
  end

  @type connection_view :: %{
          kind: :obsidian | :mcp | :pat,
          client_id: String.t() | nil,
          key_id: integer() | nil,
          name: String.t() | nil,
          software_id: String.t() | nil,
          software_version: String.t() | nil,
          verified: boolean(),
          logo: String.t() | nil,
          slug: String.t() | nil,
          vault_id: integer() | nil,
          vault_name: String.t() | nil,
          scope: String.t() | nil,
          last_used_at: DateTime.t() | nil,
          connected_at: DateTime.t() | nil,
          first_user_agent: String.t() | nil,
          first_ip: String.t() | nil,
          redirect_uris: [String.t()]
        }

  @spec list_for_user(User.t()) :: [connection_view()]
  def list_for_user(%User{} = user) do
    # Vault names are stored encrypted; bulk-decrypt once via the Vaults
    # context (RLS+tenant-scoped) and post-merge by id, rather than joining
    # at SQL level.
    vault_names = user |> Vaults.list_vaults() |> Map.new(&{&1.id, &1.name})

    (oauth_rows(user.id) ++ device_rows(user.id) ++ pat_rows(user.id))
    |> Enum.map(&Map.put(&1, :vault_name, &1.vault_id && Map.get(vault_names, &1.vault_id)))
    |> Enum.sort_by(&(&1.last_used_at || &1.connected_at), {:desc, DateTime})
  end

  defp oauth_rows(user_id) do
    from(t in RefreshToken,
      join: c in Client,
      on: c.client_id == t.client_id,
      where: t.user_id == ^user_id,
      where: is_nil(t.revoked_at),
      # Consumed tokens are superseded by rotation; the current row is the
      # unconsumed successor. Filtering both gives the live grant.
      where: is_nil(t.consumed_at),
      order_by: [desc: coalesce(t.last_used_at, t.inserted_at)],
      distinct: [t.client_id, t.vault_id],
      select: {t, c}
    )
    |> Repo.all()
    |> Enum.map(fn {t, c} ->
      identity = LogoAllowlist.resolve(c.software_id, c.redirect_uris)

      %{
        kind: String.to_existing_atom(c.kind),
        client_id: c.client_id,
        key_id: nil,
        name: identity.display_name || c.client_name,
        software_id: c.software_id,
        software_version: c.software_version,
        verified: identity.verified,
        logo: identity.logo,
        slug: identity.slug,
        vault_id: t.vault_id,
        scope: t.scope,
        last_used_at: t.last_used_at,
        connected_at: t.inserted_at,
        first_user_agent: c.first_user_agent,
        first_ip: format_inet(c.first_ip),
        redirect_uris: c.redirect_uris || []
      }
    end)
    |> Enum.sort_by(&(&1.last_used_at || &1.connected_at), {:desc, DateTime})
  end

  defp pat_rows(user_id) do
    {:ok, keys} =
      Repo.with_tenant(user_id, fn ->
        from(k in ApiKey,
          where: k.user_id == ^user_id,
          order_by: [desc: coalesce(k.last_used, k.created_at)],
          select: k
        )
        |> Repo.all()
      end)

    keys
    |> Enum.map(fn k ->
      %{
        kind: :pat,
        client_id: nil,
        key_id: k.id,
        name: k.name,
        software_id: nil,
        software_version: nil,
        verified: false,
        logo: nil,
        slug: nil,
        vault_id: nil,
        scope: nil,
        last_used_at: k.last_used,
        connected_at: k.created_at,
        first_user_agent: nil,
        first_ip: nil,
        redirect_uris: []
      }
    end)
    |> Enum.sort_by(&(&1.last_used_at || &1.connected_at), {:desc, DateTime})
  end

  defp device_rows(user_id) do
    from(rt in DeviceRefreshToken,
      where: rt.user_id == ^user_id,
      where: is_nil(rt.revoked_at),
      where: rt.expires_at > ^DateTime.utc_now(),
      distinct: rt.family_id,
      order_by: [desc: rt.inserted_at],
      select: rt
    )
    |> Repo.all(skip_tenant_check: true)
    |> Enum.map(fn rt ->
      # Hardcoded for the Obsidian plugin — the only device-flow client today.
      # If other device-flow clients are added, thread
      # device_authorizations.client_id through to discriminate.
      %{
        kind: :obsidian,
        # family_id is stable per connection lineage — safe to use as client_id
        client_id: rt.family_id,
        key_id: nil,
        name: "Obsidian Vault Sync",
        software_id: "engram-vault-sync",
        software_version: nil,
        verified: true,
        logo: "/assets/clients/engram-vault-sync.svg",
        slug: nil,
        vault_id: rt.vault_id,
        scope: nil,
        # Device flow does not stamp last_used_at on each access-token refresh.
        last_used_at: nil,
        connected_at: rt.inserted_at,
        first_user_agent: nil,
        first_ip: nil,
        redirect_uris: []
      }
    end)
  end

  # first_ip is stored as :text (migration 20260530000020 converted from :inet).
  defp format_inet(nil), do: nil
  defp format_inet(s) when is_binary(s), do: s

  # Returns true if `user_id` has any refresh token (of any state) for
  # `client_id`, confirming the client belongs to this user.
  defp any_history?(user_id, client_id) do
    Repo.exists?(
      from(t in RefreshToken,
        where: t.user_id == ^user_id and t.client_id == ^client_id
      )
    )
  end

  # Returns true if `user_id` has any device token (of any state) for
  # `family_id`, confirming the family belongs to this user.
  defp device_history?(user_id, family_id) do
    Repo.exists?(
      from(rt in DeviceRefreshToken,
        where: rt.user_id == ^user_id and rt.family_id == ^family_id
      ),
      skip_tenant_check: true
    )
  end
end
