defmodule Engram.Invites do
  @moduledoc """
  Invite links for self-host registration. Tokens are 256-bit random, shown
  once, stored as lowercase-hex SHA-256 hashes (mirrors `Accounts.hash_refresh_token/1`).
  """
  import Ecto.Query
  alias Engram.Invites.Invite
  alias Engram.Repo

  @doc """
  Creates an invite. attrs: :label, :max_uses (default 1), :expires_in_days
  (default 7; nil = never). Returns `{:ok, {raw_token, %Invite{}}}`.
  """
  def create_invite(%{id: user_id}, attrs \\ %{}) do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    hash = hash_token(raw)

    expires_at =
      case Map.get(attrs, :expires_in_days, 7) do
        nil ->
          nil

        days ->
          DateTime.utc_now()
          |> DateTime.add(days * 86_400, :second)
          |> DateTime.truncate(:second)
      end

    params = %{
      token_hash: hash,
      created_by: user_id,
      label: Map.get(attrs, :label),
      max_uses: Map.get(attrs, :max_uses, 1),
      expires_at: expires_at
    }

    case %Invite{} |> Invite.changeset(params) |> Repo.insert() do
      {:ok, invite} -> {:ok, {raw, invite}}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc """
  Atomically redeems an invite by raw token. Increments use_count only if the
  invite is active (not revoked, not expired, under cap). The `WHERE` guard
  inside the single `UPDATE` makes the cap race-free.
  """
  def redeem(raw) when is_binary(raw) do
    hash = hash_token(raw)
    now = DateTime.utc_now()

    query =
      from i in Invite,
        where:
          i.token_hash == ^hash and is_nil(i.revoked_at) and
            i.use_count < i.max_uses and
            (is_nil(i.expires_at) or i.expires_at > ^now)

    # Atomic cap: the WHERE inside this single UPDATE excludes a concurrent
    # redeemer that already pushed use_count to max_uses. Ecto's `:returning`
    # opt isn't honored on update_all, so re-fetch the row after a successful
    # count (still race-free — only the row we successfully inc'd matches).
    case Repo.update_all(query, inc: [use_count: 1]) do
      {1, _} -> {:ok, Repo.one(from i in Invite, where: i.token_hash == ^hash)}
      _ -> {:error, :invalid}
    end
  end

  @doc "Validity preview without consuming. Returns `%{valid, label, expires_at}`."
  def preview(raw) when is_binary(raw) do
    hash = hash_token(raw)
    now = DateTime.utc_now()

    invite =
      Repo.one(
        from i in Invite,
          where:
            i.token_hash == ^hash and is_nil(i.revoked_at) and
              i.use_count < i.max_uses and
              (is_nil(i.expires_at) or i.expires_at > ^now)
      )

    case invite do
      nil -> %{valid: false}
      %Invite{} = i -> %{valid: true, label: i.label, expires_at: i.expires_at}
    end
  end

  @doc "Revokes an invite by id."
  def revoke(id) do
    case Repo.get(Invite, id) do
      nil ->
        {:error, :not_found}

      invite ->
        invite
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
        |> Repo.update()
    end
  end

  @doc "Lists active (redeemable) invites, newest first."
  def list_active do
    now = DateTime.utc_now()

    Repo.all(
      from i in Invite,
        where:
          is_nil(i.revoked_at) and i.use_count < i.max_uses and
            (is_nil(i.expires_at) or i.expires_at > ^now),
        order_by: [desc: i.inserted_at]
    )
  end

  defp hash_token(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
