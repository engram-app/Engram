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

  Every "may this credential reach this vault" question resolves here.

  `vault_scope/1` reads the conn ONCE. Restrictions **intersect**: a credential
  carrying both an API-key restriction and an OAuth grant gets what BOTH allow,
  never either alone. Intersection is the only safe composition — taking one
  side would widen the credential past a restriction it is actually under.

  Folder- and group-level permissions belong here too when they arrive. The
  scope type widens; the call sites do not move. That is the point.
  """

  alias Engram.Vaults

  @type scope :: :all | MapSet.t(String.t())

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
    intersect(
      api_key_scope(assigns[:current_api_key]),
      oauth_scope(assigns[:oauth_scope_vault_ids])
    )
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

  Public because BOTH `OAuthScopeEnforce` (HTTP) and `UserSocket` (WebSocket)
  must derive the assign identically — two copies of this would drift.
  """
  @spec scope_ids_from_claims(map()) :: [String.t()] | nil
  # Must match BEFORE the non-empty clause falls through to `vault_id`/nil.
  def scope_ids_from_claims(%{"vault_ids" => []}), do: []

  def scope_ids_from_claims(%{"vault_ids" => ids}) when is_list(ids) and ids != [],
    do: Enum.map(ids, &to_string/1)

  def scope_ids_from_claims(%{"vault_id" => id}) when is_binary(id), do: [id]
  def scope_ids_from_claims(_), do: nil

  @spec allows?(scope, map()) :: boolean
  def allows?(:all, _vault), do: true
  def allows?(scope, vault), do: MapSet.member?(scope, to_string(vault.id))

  @spec check(scope, map()) :: :ok | :forbidden
  def check(scope, vault), do: if(allows?(scope, vault), do: :ok, else: :forbidden)

  @spec filter(scope, [map()]) :: [map()]
  def filter(:all, vaults), do: vaults
  def filter(scope, vaults), do: Enum.filter(vaults, &allows?(scope, &1))

  @doc false
  # Exposed for the intersection test only — the composition rule is the part
  # of this module most worth pinning down, and it is otherwise unreachable.
  def intersect_for_test(a, b), do: intersect(a, b)

  # An API key with no api_key_vaults rows is unrestricted; Vaults returns :all
  # for that and for nil (non-API-key auth). One query, already batched there.
  defp api_key_scope(nil), do: :all

  defp api_key_scope(api_key) do
    case Vaults.accessible_vault_ids(api_key) do
      :all -> :all
      ids -> MapSet.new(ids, &to_string/1)
    end
  end

  defp oauth_scope(nil), do: :all
  defp oauth_scope(ids) when is_list(ids), do: MapSet.new(ids, &to_string/1)

  defp intersect(:all, other), do: other
  defp intersect(other, :all), do: other
  defp intersect(a, b), do: MapSet.intersection(a, b)
end
