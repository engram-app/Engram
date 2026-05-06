defmodule Engram.Accounts do
  @moduledoc """
  Account management: Clerk auth, API keys, JWT.
  """

  import Ecto.Query
  alias Engram.Repo
  alias Engram.Accounts.{User, ApiKey}
  alias Engram.Auth.RefreshToken
  alias Bcrypt

  @api_key_prefix "engram_"

  def get_user!(id), do: Repo.get!(User, id, skip_tenant_check: true)

  def get_user(id), do: Repo.get(User, id, skip_tenant_check: true)

  # ── Clerk Auth ─────────────────────────────────────────────────

  @doc """
  Finds a user by external ID. Returns {:ok, user} or {:error, :user_not_found}.
  Used by local auth where users must already exist (created via /register).
  """
  def find_by_external_id(external_id) do
    case Repo.one(from(u in User, where: u.external_id == ^external_id), skip_tenant_check: true) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :user_not_found}
    end
  end

  @doc """
  Finds a user by external ID (Clerk sub), or links/creates one.

  Priority: external_id match > email match (link external_id) > create new user.
  """
  def find_or_create_by_external_id(external_id, attrs, retries \\ 1)

  def find_or_create_by_external_id(external_id, %{email: email}, retries) do
    case Repo.one(from(u in User, where: u.external_id == ^external_id), skip_tenant_check: true) do
      %User{} = user ->
        {:ok, user}

      nil ->
        case Repo.one(from(u in User, where: u.email == ^email), skip_tenant_check: true) do
          %User{} = user ->
            user
            |> Ecto.Changeset.change(%{external_id: external_id})
            |> Repo.update(skip_tenant_check: true)

          nil ->
            %User{}
            |> Ecto.Changeset.change(%{external_id: external_id, email: email})
            |> Ecto.Changeset.unique_constraint(:email, name: :users_email_lower_index)
            |> Ecto.Changeset.unique_constraint(:external_id, name: :users_clerk_id_index)
            |> Repo.insert(skip_tenant_check: true)
            |> case do
              {:ok, user} ->
                {:ok, user}

              {:error, %Ecto.Changeset{errors: [{field, _}]}}
              when field in [:email, :external_id] and retries > 0 ->
                # Concurrent request won the insert — retry finds the winner
                find_or_create_by_external_id(external_id, %{email: email}, retries - 1)

              {:error, changeset} ->
                {:error, changeset}
            end
        end
    end
  end

  # ── Local Auth ─────────────────────────────────────────────────

  # Advisory lock key for bootstrap admin assignment — arbitrary fixed integer
  @admin_bootstrap_lock 739_201

  @max_password_bytes 72

  def create_user_with_password(email, password)
      when byte_size(password) >= 8 and byte_size(password) <= @max_password_bytes do
    normalized_email = email |> String.trim() |> String.downcase()
    external_id = Ecto.UUID.generate()
    password_hash = Bcrypt.hash_pwd_salt(password)

    Repo.transaction(
      fn ->
        # Serialize bootstrap admin check so only one concurrent signup can win
        Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [@admin_bootstrap_lock])

        role = if Repo.aggregate(User, :count) == 0, do: "admin", else: "member"

        case %User{
               email: normalized_email,
               external_id: external_id,
               password_hash: password_hash,
               role: role
             }
             |> Ecto.Changeset.change()
             |> Ecto.Changeset.unique_constraint(:email, name: :users_email_lower_index)
             |> Repo.insert(skip_tenant_check: true) do
          {:ok, user} -> user
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end,
      skip_tenant_check: true
    )
  end

  def create_user_with_password(_email, password)
      when byte_size(password) > @max_password_bytes do
    {:error, :password_too_long}
  end

  def create_user_with_password(_email, _password) do
    {:error, :password_too_short}
  end

  def verify_password(email, password) do
    normalized_email = email |> String.trim() |> String.downcase()

    case Repo.one(from(u in User, where: u.email == ^normalized_email), skip_tenant_check: true) do
      %User{password_hash: hash} = user when is_binary(hash) ->
        if Bcrypt.verify_pass(password, hash),
          do: {:ok, user},
          else: {:error, :invalid_credentials}

      %User{password_hash: nil} ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}

      nil ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  # ── Refresh Tokens ─────────────────────────────────────────────

  @refresh_token_ttl_days 30

  def create_refresh_token(user, family_id \\ nil) do
    raw_token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    token_hash = hash_refresh_token(raw_token)
    family_id = family_id || Ecto.UUID.generate()

    case %RefreshToken{}
         |> RefreshToken.changeset(%{
           user_id: user.id,
           token_hash: token_hash,
           family_id: family_id,
           expires_at:
             DateTime.add(DateTime.utc_now(), @refresh_token_ttl_days * 24 * 3600, :second)
             |> DateTime.truncate(:second)
         })
         |> Repo.insert(skip_tenant_check: true) do
      {:ok, record} -> {:ok, raw_token, record}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def consume_refresh_token(raw_token) do
    token_hash = hash_refresh_token(raw_token)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    tx_result =
      Repo.transaction(
        fn ->
          # Atomically revoke: only succeeds if token exists and is not yet revoked
          revoke_query =
            from(rt in RefreshToken,
              where: rt.token_hash == ^token_hash and is_nil(rt.revoked_at),
              select: rt
            )

          case Repo.update_all(revoke_query, [set: [revoked_at: now]], skip_tenant_check: true) do
            {1, [token]} ->
              if DateTime.compare(now, token.expires_at) == :gt do
                Repo.rollback(:expired)
              else
                user =
                  Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^token.user_id),
                    skip_tenant_check: true
                  )

                case create_refresh_token(user, token.family_id) do
                  {:ok, new_raw, new_record} -> {user, new_raw, new_record}
                  {:error, _reason} -> Repo.rollback(:refresh_token_creation_failed)
                end
              end

            {0, _} ->
              # Token doesn't exist or already revoked — check which case
              case Repo.one(from(rt in RefreshToken, where: rt.token_hash == ^token_hash),
                     skip_tenant_check: true
                   ) do
                nil ->
                  Repo.rollback(:invalid_token)

                %RefreshToken{revoked_at: revoked} when not is_nil(revoked) ->
                  # Signal reuse — revocation happens AFTER the transaction commits
                  Repo.rollback({:token_reused, token_hash})

                %RefreshToken{} ->
                  Repo.rollback(:invalid_token)
              end
          end
        end,
        skip_tenant_check: true
      )

    case tx_result do
      {:ok, {user, new_raw, new_record}} ->
        {:ok, user, new_raw, new_record}

      {:error, {:token_reused, reused_token_hash}} ->
        # Revoke entire family OUTSIDE the transaction so it actually commits
        revoke_token_family(reused_token_hash)
        {:error, :token_reused}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def revoke_token_family(family_id_or_token_hash) do
    family_id =
      case Repo.one(
             from(rt in RefreshToken,
               where: rt.token_hash == ^family_id_or_token_hash,
               select: rt.family_id
             ),
             skip_tenant_check: true
           ) do
        nil -> family_id_or_token_hash
        fid -> fid
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(rt in RefreshToken,
      where: rt.family_id == ^family_id and is_nil(rt.revoked_at)
    )
    |> Repo.update_all([set: [revoked_at: now]], skip_tenant_check: true)
  end

  @doc "SHA-256 hash a raw refresh token for storage/lookup."
  def hash_refresh_token(raw_token) do
    :crypto.hash(:sha256, raw_token) |> Base.encode16(case: :lower)
  end

  # ── Encryption ─────────────────────────────────────────────────

  @doc """
  Updates encryption-related fields on a user. Used by Engram.Crypto during
  DEK provisioning. Separate from general user updates so the change surface
  is narrow.
  """
  @spec update_user_encryption(Engram.Accounts.User.t(), map()) ::
          {:ok, Engram.Accounts.User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_encryption(%User{} = user, attrs) do
    user
    |> Ecto.Changeset.cast(attrs, [:encrypted_dek, :dek_version, :key_provider])
    |> Ecto.Changeset.validate_required([:encrypted_dek, :dek_version, :key_provider])
    |> Repo.update(skip_tenant_check: true)
  end

  # ── JWT ─────────────────────────────────────────────────────────

  def generate_jwt(user) do
    # `sub` + `email` match what the active auth provider's verify_token expects
    # (Local provider rejects tokens missing them with :missing_claims). `user_id`
    # is kept for the internal-JWT fallback in TokenResolver and for any callers
    # that look it up by integer DB id.
    extra_claims = %{
      "sub" => user.external_id,
      "email" => user.email,
      "user_id" => user.id
    }

    Engram.Token.generate_and_sign!(extra_claims)
  end

  def verify_jwt(token) do
    case Engram.Token.verify_and_validate(token) do
      {:ok, claims} -> {:ok, claims}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── API Keys ────────────────────────────────────────────────────

  def create_api_key(user, name) do
    raw_key = @api_key_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    key_hash = hash_api_key(raw_key)

    result =
      Repo.with_tenant(user.id, fn ->
        %ApiKey{}
        |> ApiKey.changeset(%{key_hash: key_hash, name: name, user_id: user.id})
        |> Repo.insert()
      end)

    case result do
      {:ok, {:ok, api_key}} -> {:ok, raw_key, api_key}
      {:ok, {:error, changeset}} -> {:error, changeset}
    end
  end

  def validate_api_key(raw_key) do
    key_hash = hash_api_key(raw_key)

    case Repo.one(from(k in ApiKey, where: k.key_hash == ^key_hash, preload: :user),
           skip_tenant_check: true
         ) do
      nil -> {:error, :invalid_key}
      api_key -> {:ok, api_key.user, api_key}
    end
  end

  def list_api_keys(user) do
    {:ok, keys} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(from(k in ApiKey, where: k.user_id == ^user.id, order_by: [desc: k.created_at]))
      end)

    keys
  end

  def revoke_api_key(user, api_key_id) do
    result =
      Repo.with_tenant(user.id, fn ->
        case Repo.get_by(ApiKey, id: api_key_id, user_id: user.id) do
          nil -> {:error, :not_found}
          key -> Repo.delete(key)
        end
      end)

    case result do
      {:ok, {:ok, _}} -> :ok
      {:ok, {:error, :not_found}} -> {:error, :not_found}
      {:ok, {:error, changeset}} -> {:error, changeset}
    end
  end

  defp hash_api_key(raw_key) do
    :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
  end
end
