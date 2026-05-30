defmodule Engram.Connections do
  @moduledoc """
  Unified view of credentials a user has granted: OAuth refresh tokens
  (joined to oauth_clients) and api_keys. See
  docs/superpowers/specs/2026-05-30-connections-page-design.md.
  """

  import Ecto.Query
  alias Engram.Repo
  alias Engram.OAuth.{Client, RefreshToken}

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
  Revokes all non-revoked refresh tokens for `(user_id, client_id, vault_id)`.

  When `vault_id` is `nil`, all vaults are matched (device-flow tokens that
  carry no vault scope).

  Returns `:ok` on success (including when there are no live tokens — idempotent).
  Returns `{:error, :not_found}` when `client_id` has never been seen for
  `user_id` at all (prevents callers from revoking other users' tokens via
  guessed UUIDs).
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
