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
  alias Engram.OAuth
  alias Engram.OAuth.{Client, RefreshToken}
  alias Engram.Permissions
  alias Engram.Repo
  alias Engram.Vaults

  require Engram.OAuth

  @type kind :: :obsidian | :mcp

  # A pre-levels row whose array is unset (NULL, or `[]` from an early
  # writer): its scalar `vault_id` is then its scope (`OAuth.grant_vault_ids/1`).
  defmacrop no_vault_ids(t) do
    quote do
      is_nil(unquote(t).vault_ids) or fragment("cardinality(?) = 0", unquote(t).vault_ids)
    end
  end

  @doc """
  Returns the count of distinct active connections of `kind` for `user_id`.

  For `:obsidian`, counts BOTH OAuth refresh-token families (joined to
  oauth_clients with kind="obsidian") AND device_refresh_token families, so
  the cap is honest across both auth paths the plugin can use.

  For `:mcp`, counts only OAuth families (MCP clients use DCR, not device
  flow).

  "Active" means: not revoked, not consumed (OAuth), not expired. An OAuth
  family with ANY revoked row is not active (`OAuth.family_unrevoked/1`).
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
      # Family-wide, as enforcement reads it: one revoked row kills the grant.
      where: Engram.OAuth.family_unrevoked(t.family_id),
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
  inadvertent cross-vault revocation. With a `vault_id`, every grant that can
  reach that vault dies: one listing it, a leveled one reaching it at any
  level, and an unrestricted (all-vaults) one, which reaches every vault.

  Idempotent: a second call after revoke returns `:ok`. Unknown user+client
  combinations return `{:error, :not_found}`.
  """
  @spec revoke_oauth_family(Ecto.UUID.t(), String.t(), Ecto.UUID.t() | nil) ::
          :ok | {:error, :not_found}
  def revoke_oauth_family(user_id, client_id, vault_id) do
    query =
      from(t in RefreshToken,
        where: t.user_id == ^user_id,
        where: t.client_id == ^client_id,
        where: is_nil(t.revoked_at)
      )

    changed =
      if vault_id do
        # Pre-levels grants match BOTH shapes: grants written before
        # `vault_ids` existed carry only the scalar column, so an array-only
        # match would silently miss every legacy row and leave a "revoked"
        # connection able to mint. An unrestricted grant (no vault columns at
        # all) reaches every vault, this one included, so it goes too.
        #
        # The array is the authority whenever it is set: the scalar is matched
        # only on a row with no array. A grant narrowed off this vault may
        # still name it in the scalar (a row narrowed before the scalar was
        # repointed), and no longer reaches it.
        legacy =
          from(t in query,
            where: is_nil(t.vault_access),
            where:
              type(^vault_id, Ecto.UUID) in t.vault_ids or
                (no_vault_ids(t) and (t.vault_id == ^vault_id or is_nil(t.vault_id)))
          )

        # A leveled grant's `vault_ids` lists only its write vaults (or a
        # sentinel), so it is judged on its levels instead: any grant that can
        # reach the vault at all, read, write or through its new-vaults policy,
        # dies whole. Narrowing it would mean rewriting levels the user chose.
        revoke_rows(legacy) ++ revoke_families(leveled_reaching(query, vault_id))
      else
        revoke_rows(query)
      end

    Engram.OAuth.grants_changed(changed)

    if changed == [] and not any_history?(user_id, client_id),
      do: {:error, :not_found},
      else: :ok
  end

  # Families of the live leveled grants in `query` whose scope reaches
  # `vault_id` and satisfies `keep?`. Only the current (unconsumed) row of
  # each family is read: rotation leaves a consumed row behind per refresh.
  defp leveled_reaching(query, vault_id, keep? \\ fn _scope -> true end) do
    rows =
      Repo.all(from(t in query, where: not is_nil(t.vault_access), where: is_nil(t.consumed_at)))

    for t <- rows,
        scope = Permissions.from_claims(Engram.OAuth.access_claims(t)),
        Permissions.decide(scope, %{id: vault_id}, :read) == :ok,
        keep?.(scope),
        uniq: true,
        do: t.family_id
  end

  # Revokes every not-yet-revoked row of each family, consumed rotation
  # predecessors included, keyed on `family_id` rather than a row-id list.
  defp revoke_families([]), do: []

  defp revoke_families(families) do
    from(t in RefreshToken, where: t.family_id in ^families, where: is_nil(t.revoked_at))
    |> revoke_rows()
  end

  # Marks the rows of `query` revoked and returns `{family_id, user_id}` per
  # changed row, for `Engram.OAuth.grants_changed/1`. Every revoke here goes
  # through it, so none can forget the cache eviction or the socket
  # disconnect, and through `OAuth.revoke_refresh_tokens/2`, so none can miss
  # a successor a concurrent rotation is committing (#1974).
  defp revoke_rows(query) do
    {_n, changed} = OAuth.revoke_refresh_tokens(query)
    changed
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
    query =
      from(t in RefreshToken,
        where: t.user_id == ^user_id,
        where: t.family_id == ^family_id,
        where: is_nil(t.revoked_at)
      )

    changed = revoke_rows(query)
    Engram.OAuth.grants_changed(changed)

    if changed == [] and not oauth_family_history?(user_id, family_id),
      do: {:error, :not_found},
      else: :ok
  end

  @doc """
  Replaces the vault access of ONE live grant, `(user, client_id, family_id)`,
  with a leveled selection (`{levels, default}`, as parsed by
  `Permissions.parse_access_params/1`). The user may widen as well as narrow:
  they are the one granting.

  Every live row of the family is rewritten, the consumed rotation parent
  included, so a refresh or a grace re-issue (#1974) copies the new access
  rather than restoring the old. Under the grant lock, then the rows by id
  (rotation's order, `OAuth.revoke_refresh_tokens/2`), so a rotation in
  flight either finished first and is rewritten here, or waits and copies the
  rewritten row. Issued access tokens read their access from the row
  (`OAuth.expand_claims/1`), and the cached state is evicted on this node now
  and on every node by the `oauth_refresh_tokens_changed` trigger, so the
  change holds at once; live sockets reconnect, as on a revoke.

  `{:error, :read_only_grant}` when an `mcp:read` grant would get write
  anywhere: the client asked for read only, and `Permissions.from_claims/1`
  would cap it anyway, so the request is refused rather than silently
  narrowed. `{:error, :invalid_access}` for a vault that is not one of the
  user's active vaults; `{:error, :not_found}` when the user holds no live
  grant of that family under that client.
  """
  @spec update_oauth_grant_access(User.t(), String.t(), Ecto.UUID.t(), {map(), String.t()}) ::
          :ok | {:error, :not_found | :read_only_grant | :invalid_access}
  def update_oauth_grant_access(
        %User{} = user,
        client_id,
        family_id,
        {levels, default} = selection
      ) do
    live =
      from(t in RefreshToken,
        where: t.user_id == ^user.id,
        where: t.client_id == ^client_id,
        where: t.family_id == ^family_id,
        where: is_nil(t.revoked_at),
        # The list's notion of live: a dead family's stray unrevoked row is
        # not a grant to edit.
        where: OAuth.family_unrevoked(t.family_id)
      )

    {:ok, result} =
      Repo.transaction_after_commit(fn ->
        OAuth.lock_grants!(user.id)

        case Repo.all(from(t in live, order_by: t.id, lock: "FOR UPDATE")) do
          [] ->
            {:error, :not_found}

          [%{scope: scope} | _] ->
            if OAuth.read_only_scope?(scope) and grants_write?(levels, default),
              do: {:error, :read_only_grant},
              else: rewrite_grant(user, live, selection, scope)
        end
      end)

    result
  end

  defp grants_write?(levels, default),
    do: default == "write" or Enum.any?(levels, fn {_, l} -> l == "write" end)

  defp rewrite_grant(user, live, selection, scope) do
    case OAuth.grant_columns(user, selection, scope) do
      {:ok, columns} ->
        {_, changed} =
          Repo.update_all(from(t in live, select: {t.family_id, t.user_id}),
            set: Map.to_list(columns)
          )

        OAuth.grants_changed(changed)
        :ok

      :error ->
        {:error, :invalid_access}
    end
  end

  @doc """
  Revokes all active OAuth refresh tokens and device refresh tokens scoped to
  `vault_id` for `user_id`.

  Called at vault soft-delete time so the connections page clears immediately.
  Idempotent — safe to call twice. The owner's sockets are kicked once after
  commit if any token went (`drop_vault_from_grants/3` decides it).
  """
  @spec revoke_by_vault(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def revoke_by_vault(user_id, vault_id) do
    {devices, _} =
      Repo.update_all(
        from(rt in DeviceRefreshToken,
          where: rt.user_id == ^user_id,
          where: rt.vault_id == ^vault_id,
          where: is_nil(rt.revoked_at)
        ),
        set: [revoked_at: DateTime.utc_now(:second)]
      )

    _ = drop_vault_from_grants(user_id, vault_id, kick_owner: devices > 0)
    :ok
  end

  @doc """
  Takes `vault_id` out of the user's OAuth grants, now that it is gone:
  narrows pre-levels grants that list it among others, and revokes every
  grant left reaching no live vault. Returns how many grants it revoked.

  A multi-vault grant must NOT die because one of its vaults did — killing a
  grant over A+B+C when B is deleted costs the user access to two vaults they
  never touched. A pre-levels grant's array is narrowed instead, and its
  scalar `vault_id` repointed off the vault when it named it: that column is
  a foreign key with ON DELETE CASCADE, so leaving it would delete the
  surviving grant's rows when the vault is purged. A narrowed grant's tokens
  still CLAIM the old set, so its new one is read from the row
  (`OAuth.expand_claims/1`) and its cached state evicted like a revoke's.

  A pre-levels grant whose only vault this was, or a legacy scalar-only row,
  is revoked. Rows with both columns NULL are "all vaults" and are left
  alone. A leveled grant (#174) is judged on everything it reaches: its
  listed levels AND its new-vaults policy, never on `vault_ids`, which lists
  only its write vaults (or a sentinel). Only LIVE vaults count
  (`Permissions.reaches_anything?/2`), so a grant whose other listed vaults
  were deleted earlier goes too. Its levels are left as they are, so
  restoring the vault gives back exactly what a surviving grant held on it.
  The same rule `CleanupVault` applies to keys.

  Run at soft delete (`revoke_by_vault/2`) and again at purge (`CleanupVault`),
  which catches a grant a soft delete missed before its rows can go.

  Live vaults are read under the grant lock, so a vault created or restored
  meanwhile is judged as it is now.

  The owner's sockets are kicked once after commit when a grant changed.
  `kick_owner: true` asks for that kick even when none did, for a caller
  that revoked other credentials in the same transaction (`CleanupVault`'s
  keys, `revoke_by_vault/2`'s device tokens): one kick either way, decided
  here.
  """
  @spec drop_vault_from_grants(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def drop_vault_from_grants(user_id, vault_id, opts \\ []) do
    {:ok, revoked} =
      Repo.transaction_after_commit(fn ->
        # Rotation copies a family's state under the same lock, so a
        # successor minted concurrently cannot undo the narrowing below.
        Engram.OAuth.lock_grants!(user_id)
        do_drop_vault_from_grants(user_id, vault_id, Keyword.get(opts, :kick_owner, false))
      end)

    revoked
  end

  defp do_drop_vault_from_grants(user_id, vault_id, kick_owner) do
    {_, narrowed} =
      Repo.update_all(
        from(t in RefreshToken,
          where: t.user_id == ^user_id,
          where: is_nil(t.vault_access),
          where: type(^vault_id, Ecto.UUID) in t.vault_ids,
          where: fragment("array_length(?, 1) > 1", t.vault_ids),
          where: is_nil(t.revoked_at),
          select: {t.family_id, t.user_id},
          update: [
            set: [
              vault_ids: fragment("array_remove(?, ?)", t.vault_ids, type(^vault_id, Ecto.UUID)),
              vault_id:
                fragment(
                  "CASE WHEN ? = ? THEN (array_remove(?, ?))[1] ELSE ? END",
                  t.vault_id,
                  type(^vault_id, Ecto.UUID),
                  t.vault_ids,
                  type(^vault_id, Ecto.UUID),
                  t.vault_id
                )
            ]
          ]
        ),
        []
      )

    only_vault =
      from(t in RefreshToken,
        where: t.user_id == ^user_id,
        where: is_nil(t.revoked_at),
        where: is_nil(t.vault_access),
        where:
          (type(^vault_id, Ecto.UUID) in t.vault_ids and
             fragment("array_length(?, 1) = 1", t.vault_ids)) or
            (no_vault_ids(t) and t.vault_id == ^vault_id)
      )

    live = List.delete(Vaults.active_vault_ids(user_id), vault_id)

    revoked =
      revoke_rows(only_vault) ++
        (from(t in RefreshToken, where: t.user_id == ^user_id, where: is_nil(t.revoked_at))
         |> leveled_reaching(vault_id, &(not Permissions.reaches_anything?(&1, live)))
         |> revoke_families())

    case narrowed ++ revoked do
      [] when kick_owner ->
        Repo.after_commit(fn -> Engram.Auth.SessionInvalidator.disconnect_user(user_id) end)

      changed ->
        Engram.OAuth.grants_changed(changed)
    end

    revoked |> Enum.uniq_by(&elem(&1, 0)) |> length()
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
          # `nil` means "all vaults", not "no vaults". For a leveled
          # credential it is the vaults reached right now
          # (`leveled_vault_ids/2`). `vault_names` is positional against
          # `vault_ids`; an entry is nil when the vault is gone or outside the
          # caller's scope.
          vault_ids: [String.t()] | nil,
          vault_names: [String.t() | nil] | nil,
          scope: String.t() | nil,
          # #174 / #332: the level on each vault the caller can see that this
          # connection reaches, and the level vaults created later get.
          vault_levels: [%{vault_id: String.t(), vault_name: String.t() | nil, level: String.t()}],
          new_vaults: String.t(),
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
    |> Enum.map(fn row ->
      row = leveled_vault_ids(row, visible)

      row
      |> Map.put(:vault_names, resolve_names(row.vault_ids, vault_names))
      |> put_levels(visible)
    end)
    |> Enum.sort_by(&(&1.last_used_at || &1.connected_at), {:desc, DateTime})
  end

  # #174 / #332: each row's `access` (an `Engram.Permissions` scope, the same
  # value enforcement reads) resolved against the vaults the caller may see,
  # so a vault created after the connection shows the level it actually gets.
  defp put_levels(%{access: access} = row, visible) do
    levels =
      for v <- visible do
        %{vault_id: v.id, vault_name: v.name, level: Atom.to_string(Permissions.level(access, v))}
      end

    row
    |> Map.delete(:access)
    |> Map.merge(%{
      vault_levels: levels,
      new_vaults: Atom.to_string(Permissions.new_vault_level(access))
    })
  end

  # A leveled credential (#174 / #332) has no fixed list: a new-vaults policy
  # reaches vaults it does not name, and a `none` entry names a vault it does
  # NOT reach. So its `vault_ids` are the vaults it reaches right now (read or
  # write, as `vault_levels` shows them), never its stored columns; vaults
  # created later get `new_vaults`. Unrestricted stays nil. A key with a write
  # policy and `{A: none}` lists every vault but A, not "only A".
  defp leveled_vault_ids(%{leveled: true, access: :all} = row, _visible),
    do: %{Map.delete(row, :leveled) | vault_ids: nil}

  defp leveled_vault_ids(%{leveled: true, access: access} = row, visible),
    do: %{
      Map.delete(row, :leveled)
      | vault_ids: for(v <- visible, Permissions.decide(access, v, :read) == :ok, do: v.id)
    }

  defp leveled_vault_ids(row, _visible), do: Map.delete(row, :leveled)

  # A pre-levels grant lists its vaults (`OAuth.grant_vault_ids/1`). The
  # sentinel is not one: it is what a release that predates levels leaves
  # behind when it rewrites a leveled grant (levels dropped), and it reaches
  # nothing.
  defp grant_vault_ids(t) do
    case Engram.OAuth.grant_vault_ids(t) do
      nil -> nil
      ids -> List.delete(ids, Engram.OAuth.no_vault())
    end
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
      # unconsumed successor. Filtering both gives the grant's current row,
      # and the family check its liveness: one revoked row of the family
      # kills the grant (`OAuth.expand_claims/1`), so an unrevoked successor
      # that raced a revoke is not listed as live.
      where: is_nil(t.consumed_at),
      where: Engram.OAuth.family_unrevoked(t.family_id),
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
        vault_ids: grant_vault_ids(t),
        leveled: is_map(t.vault_access),
        scope: t.scope,
        access: Permissions.from_claims(Engram.OAuth.access_claims(t)),
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
        vault_ids: restrictions |> Map.get(k.id, []) |> Enum.map(&elem(&1, 0)) |> nil_if_empty(),
        leveled: k.default_access != nil,
        scope: nil,
        access: Permissions.from_key(k.default_access, Map.get(restrictions, k.id, [])),
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
      select: {type(akv.api_key_id, Ecto.UUID), type(akv.vault_id, Ecto.UUID), akv.level}
    )
    |> Repo.all(skip_tenant_check: true)
    |> Enum.group_by(&elem(&1, 0), fn {_key, vault, level} -> {vault, level} end)
  end

  defp nil_if_empty([]), do: nil
  defp nil_if_empty(list), do: list

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
        # The user's own label wins, as in `oauth_rows/1`.
        name: rt.label || "Obsidian Vault Sync",
        label: rt.label,
        software_id: "engram-vault-sync",
        software_version: nil,
        verified: true,
        logo: "/assets/clients/engram-vault-sync.svg",
        slug: nil,
        vault_ids: rt.vault_id && [rt.vault_id],
        scope: nil,
        access: Permissions.from_claims(%{"vault_id" => rt.vault_id}),
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
