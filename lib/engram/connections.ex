defmodule Engram.Connections do
  @moduledoc """
  Unified view of credentials a user has granted: OAuth refresh tokens
  (joined to oauth_clients) and api_keys. See
  docs/superpowers/specs/2026-05-30-connections-page-design.md.
  """

  import Ecto.Query
  alias Engram.Repo
  alias Engram.OAuth.{Client, RefreshToken}
  alias Engram.Accounts.ApiKey
  alias Engram.Connections.LogoAllowlist

  @type kind :: :obsidian | :mcp

  @doc """
  Returns the count of distinct active OAuth clients of `kind` for `user_id`.

  "Active" means at least one refresh token that is neither revoked nor
  consumed.  Multiple tokens in the same rotation family for the same client
  are collapsed into one (DISTINCT client_id).
  """
  @spec count_active(integer(), kind()) :: non_neg_integer()
  def count_active(user_id, kind) when kind in [:obsidian, :mcp] do
    kind_str = Atom.to_string(kind)

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
    now = DateTime.utc_now() |> DateTime.truncate(:second)

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

  @type connection_view :: %{
          kind: :obsidian | :mcp | :pat,
          client_id: String.t() | nil,
          key_id: integer() | nil,
          name: String.t() | nil,
          software_id: String.t() | nil,
          software_version: String.t() | nil,
          verified: boolean(),
          logo: String.t() | nil,
          vault_id: integer() | nil,
          scope: String.t() | nil,
          last_used_at: DateTime.t() | nil,
          connected_at: DateTime.t() | nil,
          first_user_agent: String.t() | nil,
          first_ip: String.t() | nil,
          redirect_uris: [String.t()]
        }

  @spec list_for_user(integer()) :: [connection_view()]
  def list_for_user(user_id) do
    oauth_rows(user_id) ++ pat_rows(user_id)
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
      logo = LogoAllowlist.lookup(c.software_id)

      %{
        kind: String.to_existing_atom(c.kind),
        client_id: c.client_id,
        key_id: nil,
        name: logo.display_name || c.client_name,
        software_id: c.software_id,
        software_version: c.software_version,
        verified: logo.verified,
        logo: logo.logo,
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

  # first_ip is stored as :text (migration 20260530000005 converted from :inet).
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
end
