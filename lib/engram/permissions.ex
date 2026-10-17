defmodule Engram.Permissions do
  @moduledoc """
  The single source of truth for what a credential may reach.

  Three credential kinds authenticate against Engram: a Clerk/local JWT (the
  user themselves, unrestricted), an API key (optionally restricted through
  `api_key_vaults`), and an OAuth grant (optionally restricted through the
  grant's `vault_ids`). Before this module each kind carried its own check and
  every caller composed them by hand — `VaultPlug` ran two in sequence,
  `McpController` chained two filters, and a third kind would have meant
  finding every site again.

  Every "may this credential reach this vault" question resolves here, and
  so does "may it change this vault": since #174 (OAuth) and #332 (API keys)
  a credential holds a LEVEL per vault (none, read, write) plus one for
  vaults created after it. OAuth grants and API keys share that one
  representation, so MCP, REST and the socket enforce both through the same
  `allows?/2` and `allows_write?/2`.

  `vault_scope/1` reads the conn ONCE. Restrictions **intersect**: a credential
  carrying both an API-key restriction and an OAuth grant gets what BOTH allow,
  never either alone. Intersection is the only safe composition — taking one
  side would widen the credential past a restriction it is actually under.

  Folder- and group-level permissions belong here too when they arrive. The
  scope type widens; the call sites do not move. That is the point.
  """

  alias Engram.Vaults

  @typedoc """
  What a credential may do to each vault.

  `:all` is the unrestricted credential (every vault, write). A bare
  `MapSet` of ids (the pre-#174 shape, still accepted from callers) is write
  on those vaults and none elsewhere. Otherwise
  `vaults` holds a level per listed vault and `default` is the level for
  every vault NOT listed, including ones created after the credential: a
  vault created later is resolved through `default` at request time, so it
  needs no backfill and no row written when it is created.
  """
  @type level :: :none | :read | :write
  @type scope :: :all | %{vaults: %{String.t() => level}, default: level} | MapSet.t(String.t())

  @levels %{"none" => :none, "read" => :read, "write" => :write}
  @rank %{none: 0, read: 1, write: 2}

  @doc """
  Resolves everything restricting this request into one scope.

  Takes a `Plug.Conn`, a `Phoenix.Socket`, or a bare assigns map. WebSocket
  channels have no conn — plugs never run for a socket connect — so accepting
  assigns directly is what lets HTTP and WS share one implementation instead of
  growing a second copy for channels.
  """
  @spec vault_scope(Plug.Conn.t() | Phoenix.Socket.t() | map()) :: scope
  def vault_scope(%{assigns: assigns}), do: vault_scope(assigns)

  def vault_scope(assigns) when is_map(assigns) do
    intersect(api_key_scope(assigns[:current_api_key]), oauth_part(assigns))
  end

  @doc """
  Normalizes OAuth vault-scope claims into the assign both transports carry.

  `vault_ids` first, falling back to the legacy scalar `vault_id` so refresh
  tokens minted before multi-vault grants shipped keep their binding. `nil`
  means unrestricted. An empty list means "no vaults" and denies everything: it
  is never written (mint rejects it), so encountering one means a malformed
  token, and a malformed token must not resolve to full access. Without the
  explicit clause an empty list falls through to the scalar clause and then to
  `nil`, which reads as `:all` — the one fail-OPEN cell in the matrix.

  This is the readable-id list only. Levels come from `from_claims/1`.
  """
  @spec scope_ids_from_claims(map()) :: [String.t()] | nil
  # Must match BEFORE the non-empty clause falls through to `vault_id`/nil.
  def scope_ids_from_claims(%{"vault_ids" => []}), do: []

  def scope_ids_from_claims(%{"vault_ids" => ids}) when is_list(ids) and ids != [],
    do: Enum.map(ids, &to_string/1)

  def scope_ids_from_claims(%{"vault_id" => id}) when is_binary(id), do: [id]
  def scope_ids_from_claims(_), do: nil

  @doc """
  An OAuth access token's claims as a scope.

  Public because BOTH `OAuthScopeEnforce` (HTTP) and `UserSocket` (WebSocket)
  must derive it identically — two copies would drift.

    * `vault_access` / `default_access` present (#174): those levels. An
      absent `default_access` is `none`: picking vaults never grants future
      ones by accident.
    * neither present: the pre-levels grant. Its vault ids are write, every
      other vault none, and no vault ids at all means every vault write.
    * `mcp:read` caps every level at read, whatever the levels say.

  Any malformed level reads as `none`. A malformed token must deny.
  """
  @spec from_claims(map()) :: scope
  def from_claims(claims) when is_map(claims) do
    claims
    |> claims_scope()
    |> cap_read_only(Engram.OAuth.read_only_scope?(claims["scope"]))
  end

  defp claims_scope(%{"vault_access" => access} = claims) when is_map(access),
    do: from_levels(access, parse_level(Map.get(claims, "default_access", "none")))

  defp claims_scope(%{"vault_access" => _}), do: from_levels(%{}, :none)

  defp claims_scope(%{"default_access" => default}), do: from_levels(%{}, parse_level(default))

  defp claims_scope(claims) do
    case scope_ids_from_claims(claims) do
      nil -> :all
      ids -> from_levels(Map.new(ids, &{&1, :write}), :none)
    end
  end

  defp cap_read_only(scope, false), do: scope

  defp cap_read_only(scope, true) do
    %{vaults: vaults, default: default} = expand(scope)

    from_levels(
      Map.new(vaults, fn {id, l} -> {id, min_level(l, :read)} end),
      min_level(default, :read)
    )
  end

  @doc """
  Builds a scope from a level per vault and a level for every other vault.
  Levels may be atoms or their strings; anything else is `:none`.
  """
  @spec from_levels(map(), level() | String.t()) :: scope
  def from_levels(vaults, default) when is_map(vaults) do
    vaults = Map.new(vaults, fn {id, l} -> {to_string(id), parse_level(l)} end)
    default = parse_level(default)

    if default == :write and Enum.all?(vaults, fn {_, l} -> l == :write end),
      do: :all,
      else: %{vaults: vaults, default: default}
  end

  @doc """
  Reads the `vault_access` / `default_access` pair a consent or key-creation
  request sends.

  `{:ok, nil}` when neither is present: the caller keeps its pre-levels
  behaviour. `{:ok, {levels, default}}` with string levels otherwise.
  `:error` for an unknown level, a non-object `vault_access`, or a selection
  that reaches nothing now or later (refused rather than minted).
  """
  @spec parse_access_params(map()) :: {:ok, nil | {map(), String.t()}} | :error
  def parse_access_params(params) when is_map(params) do
    access = Map.get(params, "vault_access")
    default = Map.get(params, "default_access")

    cond do
      is_nil(access) and is_nil(default) -> {:ok, nil}
      not (is_nil(access) or is_map(access)) -> :error
      true -> validate_access(access || %{}, default || "none")
    end
  end

  defp validate_access(access, default) do
    valid? =
      Map.has_key?(@levels, default) and
        Enum.all?(access, fn {id, l} -> is_binary(id) and Map.has_key?(@levels, l) end)

    reaches_something? = default != "none" or Enum.any?(access, fn {_, l} -> l != "none" end)

    if valid? and reaches_something?, do: {:ok, {access, default}}, else: :error
  end

  @doc """
  Turns a parsed `{levels, default}` selection (`parse_access_params/1`) into
  what a grant or key stores: `{:ok, %{canonical_vault_id => level}, default}`.

    * Every listed vault must be one of the user's ACTIVE vaults, or `:error`.
    * With a `none` policy, `none` entries are dropped: they say what the
      policy already says, and on an OAuth grant each one is token bytes.
    * With a non-`none` policy, every vault soft-deleted right now is
      recorded as `none`. "Vaults you create later" must not cover a vault
      that already existed and was deleted: restoring it later would
      otherwise hand it to this credential through the policy.
  """
  @spec resolve_access(map(), {map(), String.t()}) ::
          {:ok, %{String.t() => String.t()}, String.t()} | :error
  def resolve_access(user, {levels, default}) do
    with {:ok, canonical} <- Vaults.owned_active_ids(user, Map.keys(levels)) do
      listed = Map.new(levels, fn {raw, l} -> {Map.fetch!(canonical, raw), l} end)

      access =
        if default == "none",
          do: Map.reject(listed, fn {_, l} -> l == "none" end),
          else: user |> Vaults.deleted_vault_ids() |> Map.new(&{&1, "none"}) |> Map.merge(listed)

      {:ok, access, default}
    end
  end

  @doc """
  An API key's scope from its `default_access` and its `api_key_vaults`
  rows (`{vault_id, level}`, a NULL level being write). The one reading of a
  key's columns, shared by enforcement, the connections list and vault
  cleanup.

  `default_access` NULL is a pre-#332 key: no rows is every vault, rows are
  write on exactly those.
  """
  @spec from_key(String.t() | nil, [{String.t(), String.t() | nil}]) :: scope
  def from_key(nil, []), do: :all
  def from_key(nil, rows), do: from_levels(Map.new(rows, fn {v, _} -> {v, :write} end), :none)

  def from_key(default, rows),
    do: from_levels(Map.new(rows, fn {v, l} -> {v, l || "write"} end), default)

  @doc """
  Whether the scope reaches any LIVE vault, listed or created later.
  `live_ids` are the ids of the user's active vaults: a listed vault that is
  soft-deleted or purged counts for nothing, so a credential whose listed
  vaults are all gone and whose new-vaults policy is `none` reaches nothing.
  """
  @spec reaches_anything?(scope, Enumerable.t()) :: boolean
  def reaches_anything?(scope, live_ids), do: any_live?(scope, live_ids, &(&1 != :none))

  @doc """
  Whether ANY live vault, listed or created later, is writable (`live_ids` as
  in `reaches_anything?/2`).
  """
  @spec writable_anywhere?(scope, Enumerable.t()) :: boolean
  def writable_anywhere?(scope, live_ids), do: any_live?(scope, live_ids, &(&1 == :write))

  defp any_live?(:all, _live_ids, _pred), do: true

  defp any_live?(scope, live_ids, pred) do
    %{vaults: vaults, default: default} = expand(scope)
    live = MapSet.new(live_ids, &to_string/1)

    pred.(default) or
      Enum.any?(vaults, fn {id, l} -> pred.(l) and MapSet.member?(live, id) end)
  end

  @doc """
  The level `vault` is LISTED at, ignoring the new-vaults policy (`:none`
  when it is not listed). Soft-deleted vaults are judged by this: the policy
  is for vaults created after the credential, and a deleted vault is not one,
  so restoring it needs an explicit write level. The unrestricted credential
  (`:all`) keeps write, as before levels.
  """
  @spec explicit_level(scope, map()) :: level
  def explicit_level(:all, _vault), do: :write
  def explicit_level(%MapSet{} = ids, vault), do: level(ids, vault)
  def explicit_level(%{vaults: vaults}, vault), do: Map.get(vaults, to_string(vault.id), :none)

  @doc """
  A scope in the request shape (`vault_access` + `default_access`, string
  levels): what the consent and key-creation responses echo back, so a
  client can check the server stored no more than it asked for. `:all` is
  every vault at write.
  """
  @spec to_params(scope) :: %{
          vault_access: %{String.t() => String.t()},
          default_access: String.t()
        }
  def to_params(scope) do
    %{vaults: vaults, default: default} = expand(scope)

    %{
      vault_access: Map.new(vaults, fn {id, l} -> {id, Atom.to_string(l)} end),
      default_access: Atom.to_string(default)
    }
  end

  @doc """
  What an API key may do, read back from storage, in the request shape
  (#332): key creation echoes it, and the key form compares it with what it
  asked for and revokes a key that came out wider.
  """
  @spec key_params(Engram.Accounts.ApiKey.t()) :: %{
          vault_access: %{String.t() => String.t()},
          default_access: String.t()
        }
  def key_params(api_key), do: to_params(vault_scope(%{current_api_key: api_key}))

  @doc "The credential's level on `vault`."
  @spec level(scope, map()) :: level
  def level(:all, _vault), do: :write

  def level(%MapSet{} = ids, vault),
    do: if(MapSet.member?(ids, to_string(vault.id)), do: :write, else: :none)

  def level(%{vaults: vaults, default: default}, vault),
    do: Map.get(vaults, to_string(vault.id), default)

  @spec allows?(scope, map()) :: boolean
  def allows?(scope, vault), do: level(scope, vault) != :none

  @doc "Whether the credential may change `vault`: read access is not enough."
  @spec allows_write?(scope, map()) :: boolean
  def allows_write?(scope, vault), do: level(scope, vault) == :write

  @doc "The level a vault created after the credential gets."
  @spec new_vault_level(scope) :: level
  def new_vault_level(:all), do: :write
  def new_vault_level(%MapSet{}), do: :none
  def new_vault_level(%{default: default}), do: default

  @doc """
  The one access decision: may a credential with `scope` act on `vault` at
  `need`? REST (`VaultPlug`), MCP and the sockets (`EngramWeb.ChannelAccess`)
  all ask here. `:revoked` is a socket's grant that is gone
  (`EngramWeb.ChannelGate.vault_scope/1`).
  """
  @spec decide(scope | :revoked, map(), :read | :write) ::
          :ok | :read_only | :forbidden | :revoked
  def decide(:revoked, _vault, _need), do: :revoked

  def decide(scope, vault, need) do
    case level(scope, vault) do
      :none -> :forbidden
      :read when need == :write -> :read_only
      _reachable -> :ok
    end
  end

  @spec filter(scope, [map()]) :: [map()]
  def filter(:all, vaults), do: vaults
  def filter(scope, vaults), do: Enum.filter(vaults, &allows?(scope, &1))

  # An API key's cached scope (`Vaults.accessible_vault_ids/1`): `:all` and a
  # bare id list are pre-levels keys (no rows = every vault, rows = exactly
  # those, write); a leveled key is cached as a scope already.
  defp api_key_scope(nil), do: :all

  defp api_key_scope(api_key) do
    case Vaults.accessible_vault_ids(api_key) do
      :all -> :all
      ids when is_list(ids) -> from_levels(Map.new(ids, &{&1, :write}), :none)
      %{vaults: _, default: _} = scope -> scope
    end
  end

  # `oauth_access` is what `OAuthScopeEnforce` and `UserSocket` assign. A bare
  # `oauth_scope_vault_ids` (assigns built without either) is the pre-levels shape.
  defp oauth_part(%{oauth_access: nil} = assigns), do: legacy_oauth_part(assigns)
  defp oauth_part(%{oauth_access: scope}), do: scope
  defp oauth_part(assigns), do: legacy_oauth_part(assigns)

  defp legacy_oauth_part(%{oauth_scope_vault_ids: ids}) when is_list(ids),
    do: claims_scope(%{"vault_ids" => ids})

  defp legacy_oauth_part(_assigns), do: :all

  # Per vault, the LOWER of the two levels: a credential restricted twice gets
  # what both allow. Every vault either side lists is materialised; the rest
  # resolve through the lower of the two defaults.
  defp intersect(:all, other), do: other
  defp intersect(other, :all), do: other

  defp intersect(a, b) do
    a = expand(a)
    b = expand(b)
    ids = Map.keys(a.vaults) ++ Map.keys(b.vaults)

    from_levels(
      Map.new(ids, &{&1, min_level(level(a, %{id: &1}), level(b, %{id: &1}))}),
      min_level(a.default, b.default)
    )
  end

  defp expand(:all), do: %{vaults: %{}, default: :write}
  defp expand(%MapSet{} = ids), do: %{vaults: Map.new(ids, &{&1, :write}), default: :none}
  defp expand(scope), do: scope

  defp min_level(a, b), do: if(@rank[a] <= @rank[b], do: a, else: b)

  defp parse_level(l) when is_atom(l) and is_map_key(@rank, l), do: l
  defp parse_level(l) when is_binary(l), do: Map.get(@levels, l, :none)
  defp parse_level(_), do: :none
end
