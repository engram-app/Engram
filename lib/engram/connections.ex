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
      revoke via `DELETE /api/connections/oauth/:client_id`. One client can
      hold SEVERAL grants (different vault sets, different labels), and each
      is one row keyed by `family_id` — pass `?family_id=` to revoke the row
      the user actually clicked, or omit it to disconnect the whole client.
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

  Client-grain: every grant the client holds dies, which is what the
  connection-cap swap flows need — `count_active/2` counts DISTINCT
  `client_id`, so freeing a cap slot means killing the client, not one of its
  grants. To revoke a single grant the user picked off the connections list,
  use `revoke_oauth_grant/2`.

  When `vault_id` is `nil`, ALL vault scopes for that user+client are revoked —
  this is the device-flow case where the original grant had no vault binding.
  Vault-scoped controllers MUST pass the originating `vault_id` to avoid
  inadvertent cross-vault revocation.

  Idempotent: a second call after revoke returns `:ok`. Unknown user+client
  combinations return `{:error, :not_found}`.
  """
  @spec revoke_oauth_family(Ecto.UUID.t(), String.t(), Ecto.UUID.t() | nil) ::
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
        # Matches BOTH shapes: grants written before `vault_ids` existed carry
        # only the scalar column, so an array-only match would silently miss
        # every legacy row and leave a "revoked" connection able to mint.
        from(t in query,
          where: type(^vault_id, Ecto.UUID) in t.vault_ids or t.vault_id == ^vault_id
        )
      else
        query
      end

    case Repo.update_all(query, set: [revoked_at: now]) do
      {0, _} -> if any_history?(user_id, client_id), do: :ok, else: {:error, :not_found}
      {_, _} -> :ok
    end
  end

  @doc """
  Revokes (sets `revoked_at = now`) the active OAuth refresh tokens of ONE
  grant lineage, `(user_id, family_id)`.

  `family_id` is minted per authorization-code exchange and carried unchanged
  across every rotation, so it names exactly the grant the user consented to —
  and exactly one row of `list_for_user/2`. A client the user authorized twice
  (say one grant over their work vaults, another over personal) has two
  families, and revoking one leaves the other minting.

  Same error semantics as `revoke_device_family/2`: idempotent `:ok` once the
  family is known, `{:error, :not_found}` for a family this user never held.
  """
  @spec revoke_oauth_grant(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def revoke_oauth_grant(user_id, family_id) do
    now = DateTime.utc_now(:second)

    query =
      from(t in RefreshToken,
        where: t.user_id == ^user_id,
        where: t.family_id == ^family_id,
        where: is_nil(t.revoked_at)
      )

    case Repo.update_all(query, set: [revoked_at: now]) do
      {0, _} -> if oauth_family_history?(user_id, family_id), do: :ok, else: {:error, :not_found}
      {_, _} -> :ok
    end
  end

  @doc """
  Revokes all active OAuth refresh tokens and device refresh tokens scoped to
  `vault_id` for `user_id`.

  Called at vault soft-delete time so the connections page clears immediately.
  Idempotent — safe to call twice.
  """
  @spec revoke_by_vault(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def revoke_by_vault(user_id, vault_id) do
    now = DateTime.utc_now(:second)

    # A multi-vault grant must NOT die because one of its vaults did — killing
    # a grant over A+B+C when B is deleted costs the user access to two vaults
    # they never touched. Narrow the array first; the revoke pass below then
    # no longer matches the narrowed row (the deleted id is gone from it), so
    # only grants with nothing left standing get revoked.
    Repo.update_all(
      from(t in RefreshToken,
        where: t.user_id == ^user_id,
        where: type(^vault_id, Ecto.UUID) in t.vault_ids,
        where: fragment("array_length(?, 1) > 1", t.vault_ids),
        where: is_nil(t.revoked_at),
        update: [
          set: [
            vault_ids: fragment("array_remove(?, ?)", t.vault_ids, type(^vault_id, Ecto.UUID))
          ]
        ]
      ),
      []
    )

    # Revoke outright when the deleted vault was the grant's ONLY one, and for
    # legacy scalar-only rows which have no array to narrow. Rows with both
    # columns NULL are "all vaults" and are deliberately left alone.
    Repo.update_all(
      from(t in RefreshToken,
        where: t.user_id == ^user_id,
        where: is_nil(t.revoked_at),
        where:
          (type(^vault_id, Ecto.UUID) in t.vault_ids and
             fragment("array_length(?, 1) = 1", t.vault_ids)) or
            (is_nil(t.vault_ids) and t.vault_id == ^vault_id)
      ),
      set: [revoked_at: now]
    )

    Repo.update_all(
      from(rt in DeviceRefreshToken,
        where: rt.user_id == ^user_id,
        where: rt.vault_id == ^vault_id,
        where: is_nil(rt.revoked_at)
      ),
      set: [revoked_at: now]
    )

    :ok
  end

  @doc """
  Revokes (sets `revoked_at = now`) all active device refresh tokens for
  `(user_id, family_id)`.

  Idempotent: a second call after all tokens are already revoked returns `:ok`.
  Unknown `(user_id, family_id)` combinations return `{:error, :not_found}`.
  """
  @spec revoke_device_family(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok | {:error, :not_found}
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
          # The grant lineage this row IS, and the id its revoke keys on. One
          # client can hold several; `client_id` alone cannot tell them apart.
          # nil for PATs, which have no lineage.
          family_id: Ecto.UUID.t() | nil,
          key_id: integer() | nil,
          name: String.t() | nil,
          # The user's own string, when they chose one. `name` falls back
          # through the client's self-reported and catalog names; this does not.
          label: String.t() | nil,
          software_id: String.t() | nil,
          software_version: String.t() | nil,
          verified: boolean(),
          logo: String.t() | nil,
          slug: String.t() | nil,
          # `nil` means "all vaults", not "no vaults". `vault_names` is
          # positional against `vault_ids`; an entry is nil when the vault is
          # gone or outside the caller's scope.
          vault_ids: [String.t()] | nil,
          vault_names: [String.t() | nil] | nil,
          scope: String.t() | nil,
          last_used_at: DateTime.t() | nil,
          connected_at: DateTime.t() | nil,
          first_user_agent: String.t() | nil,
          first_ip: String.t() | nil,
          # The redirect the grant was DELIVERED to (nil for non-OAuth rows and
          # for grants predating #1204). Distinct from `redirect_uris`, which is
          # everything the client registered and could have chosen from.
          redirect_uri: String.t() | nil,
          redirect_uris: [String.t()],
          cimd_url: String.t() | nil
        }

  @doc """
  Lists the user's connections, resolving vault names through `scope`.

  `scope` is what the REQUEST's credential may reach, not what the user owns.
  `RequireSession` gates this route and now rejects OAuth grants as well as API
  keys, so this filter is defence in depth rather than the only guard: it still
  covers a grant row with a NULL `scope` claim, which the plug cannot
  discriminate, and it keeps the route correct if it is ever moved off that
  pipeline.
  """
  @spec list_for_user(User.t(), Engram.Permissions.scope()) :: [connection_view()]
  def list_for_user(%User{} = user, scope \\ :all) do
    # Vault names are stored encrypted; bulk-decrypt once via the Vaults
    # context (RLS+tenant-scoped) and post-merge by id, rather than joining
    # at SQL level. Flat call, NOT a pipe: filter/2 takes the scope first and a
    # reversed call fails at runtime, not compile time.
    visible = Engram.Permissions.filter(scope, Vaults.list_vaults(user))
    vault_names = Map.new(visible, &{&1.id, &1.name})

    (oauth_rows(user.id) ++ device_rows(user.id) ++ pat_rows(user.id))
    |> Enum.map(&Map.put(&1, :vault_names, resolve_names(&1.vault_ids, vault_names)))
    |> Enum.sort_by(&(&1.last_used_at || &1.connected_at), {:desc, DateTime})
  end

  # nil vault_ids = all vaults; there is no name list to build for it.
  defp resolve_names(nil, _names), do: nil
  defp resolve_names(ids, names), do: Enum.map(ids, &Map.get(names, &1))

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
      # One row per grant lineage, exactly as `device_rows/1` keys on its own
      # family_id. Rotation successors share a family so they still collapse,
      # while two separate authorizations of one client stay two rows even
      # when they cover the same vaults — and each row's Disconnect can then
      # revoke only itself. Keying on the vault columns instead would merge
      # those two into a row no single revoke could clear.
      distinct: t.family_id,
      select: {t, c}
    )
    |> Repo.all()
    |> Enum.map(fn {t, c} ->
      # `t.redirect_uri` (the grant's), NOT `c.redirect_uris` (the client's
      # registered list). A client may register several and pick per
      # authorization, so only the one the code was delivered to proves
      # anything. See #1204. NULL on pre-#1204 grants -> unverified.
      identity =
        LogoAllowlist.resolve(c.software_id, t.redirect_uri, c.client_name, c.cimd_url)

      %{
        kind: String.to_existing_atom(c.kind),
        client_id: c.client_id,
        family_id: t.family_id,
        key_id: nil,
        # The user's own label wins. `identity.display_name` is the CLIENT's
        # name, which is identical across two grants for the same client — the
        # exact case a label exists to disambiguate.
        name: t.label || identity.display_name || c.client_name,
        # Also emitted on its own. `name` collapses three sources, and the web
        # app prefers the catalog spelling over a client's self-reported one —
        # which would silently outrank the user's label, the one string they
        # chose themselves to tell two grants for the same client apart.
        label: t.label,
        software_id: c.software_id,
        software_version: c.software_version,
        verified: identity.verified,
        logo: identity.logo,
        slug: identity.slug,
        # Legacy rows carry only the scalar; lift it into the array shape so
        # every branch of this list emits the SAME type.
        vault_ids: t.vault_ids || (t.vault_id && [t.vault_id]),
        scope: t.scope,
        last_used_at: t.last_used_at,
        connected_at: t.inserted_at,
        first_user_agent: c.first_user_agent,
        first_ip: format_inet(c.first_ip),
        redirect_uri: t.redirect_uri,
        redirect_uris: c.redirect_uris || [],
        cimd_url: c.cimd_url
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

    restrictions = api_key_vault_ids(Enum.map(keys, & &1.id))

    keys
    |> Enum.map(fn k ->
      %{
        kind: :pat,
        client_id: nil,
        family_id: nil,
        key_id: k.id,
        name: k.name,
        # A key's name IS user-chosen, so it is its own label.
        label: k.name,
        software_id: nil,
        software_version: nil,
        verified: false,
        logo: nil,
        slug: nil,
        # Was hardcoded nil, which reads as "all vaults" — a key restricted to
        # one vault was displayed as reaching every one of them.
        vault_ids: restrictions[k.id],
        scope: nil,
        last_used_at: k.last_used,
        connected_at: k.created_at,
        first_user_agent: nil,
        first_ip: nil,
        redirect_uri: nil,
        redirect_uris: [],
        cimd_url: nil
      }
    end)
    |> Enum.sort_by(&(&1.last_used_at || &1.connected_at), {:desc, DateTime})
  end

  # `api_key_vaults` has no user_id of its own, so RLS cannot scope it; the
  # ids come from keys already filtered by user_id above. No rows for a key
  # means unrestricted, which is `nil` on the wire — same as an OAuth grant
  # with no vault set.
  defp api_key_vault_ids([]), do: %{}

  defp api_key_vault_ids(key_ids) do
    from(akv in "api_key_vaults",
      where: akv.api_key_id in ^Enum.map(key_ids, &Ecto.UUID.dump!/1),
      select: {type(akv.api_key_id, Ecto.UUID), type(akv.vault_id, Ecto.UUID)}
    )
    |> Repo.all(skip_tenant_check: true)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
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
        family_id: rt.family_id,
        key_id: nil,
        name: "Obsidian Vault Sync",
        # Device flow has no consent screen, so no user-chosen label.
        label: nil,
        software_id: "engram-vault-sync",
        software_version: nil,
        verified: true,
        logo: "/assets/clients/engram-vault-sync.svg",
        slug: nil,
        vault_ids: rt.vault_id && [rt.vault_id],
        scope: nil,
        # Device flow does not stamp last_used_at on each access-token refresh.
        last_used_at: nil,
        connected_at: rt.inserted_at,
        first_user_agent: nil,
        first_ip: nil,
        redirect_uri: nil,
        redirect_uris: [],
        cimd_url: nil
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

  # Returns true if `user_id` has any refresh token (of any state) in
  # `family_id`, confirming the grant lineage belongs to this user.
  defp oauth_family_history?(user_id, family_id) do
    Repo.exists?(
      from(t in RefreshToken,
        where: t.user_id == ^user_id and t.family_id == ^family_id
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
