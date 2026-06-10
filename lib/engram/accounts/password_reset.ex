defmodule Engram.Accounts.PasswordReset do
  @moduledoc """
  Password reset tokens: 256-bit, lowercase-hex hashed at rest, single-use,
  short-lived (~1h). Used by admin-issued reset links (no SMTP). Mirrors the
  invite primitive in `Engram.Invites`. A successful redeem also revokes the
  user's other refresh tokens (spec §8/§10).
  """
  import Ecto.Query
  alias Engram.Accounts
  alias Engram.Accounts.PasswordReset.Token
  alias Engram.Accounts.User
  alias Engram.Repo

  defmodule Token do
    @moduledoc false
    use Engram.Schema
    import Ecto.Changeset

    schema "password_reset_tokens" do
      field :user_id, :id
      field :token_hash, :string, redact: true
      field :expires_at, :utc_datetime
      field :used_at, :utc_datetime
      field :created_by, :id
      timestamps(type: :utc_datetime, updated_at: false)
    end

    def changeset(struct, attrs) do
      struct
      |> cast(attrs, [:user_id, :token_hash, :expires_at, :created_by])
      |> validate_required([:user_id, :token_hash, :expires_at])
    end
  end

  @ttl_seconds 3600

  @doc "Mints a reset token for `user`, issued by `issuer` (admin or self)."
  def issue(%User{} = user, %User{} = issuer) do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    hash = hash_token(raw)

    expires =
      DateTime.utc_now() |> DateTime.add(@ttl_seconds, :second) |> DateTime.truncate(:second)

    %Token{}
    |> Token.changeset(%{
      user_id: user.id,
      token_hash: hash,
      expires_at: expires,
      created_by: issuer.id
    })
    |> Repo.insert(skip_tenant_check: true)
    |> case do
      {:ok, tok} -> {:ok, {raw, tok}}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc """
  Redeems a reset token and sets a new password. Single-use + expiry-checked.
  On success, revokes the user's existing refresh tokens (spec §8/§10).
  """
  def redeem(raw, new_password) when is_binary(raw) do
    hash = hash_token(raw)
    now = DateTime.utc_now()

    Repo.transaction(
      fn ->
        tok =
          Repo.one(
            from(t in Token,
              where: t.token_hash == ^hash and is_nil(t.used_at) and t.expires_at > ^now,
              lock: "FOR UPDATE"
            ),
            skip_tenant_check: true
          )

        case tok do
          nil ->
            Repo.rollback(:invalid)

          %Token{} = t ->
            user = Repo.get!(User, t.user_id, skip_tenant_check: true)

            case Accounts.update_password(user, new_password) do
              {:ok, updated} ->
                t
                |> Ecto.Changeset.change(used_at: DateTime.truncate(now, :second))
                |> Repo.update!(skip_tenant_check: true)

                # Spec §8/§10: a reset invalidates all existing sessions.
                Accounts.revoke_all_user_tokens(updated)

                updated

              {:error, reason} ->
                Repo.rollback(reason)
            end
        end
      end,
      skip_tenant_check: true
    )
    |> normalize()
  end

  defp normalize({:ok, user}), do: {:ok, user}
  defp normalize({:error, :invalid}), do: {:error, :invalid}
  defp normalize({:error, other}), do: {:error, other}

  defp hash_token(raw), do: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
end
