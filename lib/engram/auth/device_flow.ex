defmodule Engram.Auth.DeviceFlow do
  @moduledoc """
  Manages the OAuth device authorization flow.

  Flow: plugin starts → user authorizes in browser → plugin exchanges code for tokens.
  """

  import Ecto.Query

  alias Engram.{Accounts, Vaults}
  alias Engram.Auth.{DeviceAuthorization, DeviceRefreshToken}
  alias Engram.Repo

  require Logger

  @device_code_bytes 32
  @refresh_token_prefix "engram_rt_"
  @refresh_token_bytes 32
  @refresh_token_ttl_days 90
  @device_code_ttl_seconds 300
  # Leeway window after a refresh token is rotated during which the old token is
  # still accepted, so a client that loses the rotated token (e.g. a plugin
  # reload mid-refresh, or a brief concurrent retry) can recover instead of
  # being forced to re-login. Auth0 calls this the "rotation overlap period" and
  # recommends the shortest viable value; plugin reload races resolve in <1s.
  @refresh_leeway_seconds 30

  # Characters excluding ambiguous: 0, O, 1, I, L
  @user_code_chars ~c"ABCDEFGHJKMNPQRSTUVWXYZ2345679"

  def start_device_flow(client_id) do
    device_code = Base.encode16(:crypto.strong_rand_bytes(@device_code_bytes), case: :lower)
    user_code = generate_user_code()

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@device_code_ttl_seconds, :second)
      |> DateTime.truncate(:second)

    %DeviceAuthorization{}
    |> DeviceAuthorization.changeset(%{
      device_code: device_code,
      user_code: user_code,
      client_id: client_id,
      status: "pending",
      expires_at: expires_at
    })
    |> Repo.insert(skip_tenant_check: true)
  end

  def authorize_device(user_code, user, vault_id) do
    now = DateTime.utc_now()

    query =
      from(da in DeviceAuthorization,
        where: da.user_code == ^user_code and da.status == "pending" and da.expires_at > ^now
      )

    case Repo.one(query, skip_tenant_check: true) do
      nil ->
        {:error, :not_found_or_expired}

      auth ->
        case Repo.one(
               from(v in Vaults.Vault, where: v.id == ^vault_id and v.user_id == ^user.id),
               skip_tenant_check: true
             ) do
          nil ->
            {:error, :vault_not_found}

          _vault ->
            auth
            |> DeviceAuthorization.authorize_changeset(%{
              user_id: user.id,
              vault_id: vault_id,
              status: "authorized"
            })
            |> Repo.update(skip_tenant_check: true)
        end
    end
  end

  def exchange_device_code(device_code) do
    now = DateTime.utc_now()

    query =
      from(da in DeviceAuthorization,
        where: da.device_code == ^device_code and da.expires_at > ^now,
        preload: [:user]
      )

    case Repo.one(query, skip_tenant_check: true) do
      nil ->
        {:error, :expired_or_invalid}

      %{status: "pending"} ->
        {:error, :authorization_pending}

      %{status: "authorized", user: %{id: user_id}} = auth ->
        {:ok, _} = result = consume_and_issue_tokens(auth)
        _ = Engram.Onboarding.record_action(user_id, :plugin_connected)
        result

      _other ->
        {:error, :expired_or_invalid}
    end
  end

  def refresh_access_token(raw_refresh_token) do
    token_hash = hash_token(raw_refresh_token)
    now = DateTime.utc_now()
    leeway_cutoff = DateTime.add(now, -@refresh_leeway_seconds, :second)

    # Look the token up regardless of revocation state — a *revoked* token still
    # has to be classified (benign retry within leeway vs. reuse breach), not
    # silently rejected. Expired tokens are out of scope entirely.
    query =
      from(rt in DeviceRefreshToken,
        where: rt.token_hash == ^token_hash and rt.expires_at > ^now,
        preload: [:user]
      )

    case Repo.one(query, skip_tenant_check: true) do
      nil ->
        {:error, :invalid_refresh_token}

      %{revoked_at: nil} = old_token ->
        # Active token: normal single-use rotation. Stamp revoked_at so the
        # leeway is measured from this first rotation and can't be slid forward.
        old_token
        |> Ecto.Changeset.change(%{revoked_at: DateTime.truncate(now, :second)})
        |> Repo.update!(skip_tenant_check: true)

        issue_child(old_token)

      old_token ->
        if DateTime.compare(old_token.revoked_at, leeway_cutoff) == :gt do
          # Revoked within the leeway: benign retry (lost rotation, concurrent
          # request). Issue a child in the same family without re-revoking.
          issue_child(old_token)
        else
          # Reuse of a token revoked outside the leeway → breach (RFC 9700
          # §4.14.2). Invalidate the whole family so the legitimate holder of
          # the current token is forced to re-authenticate.
          invalidate_family(old_token)
          {:error, :invalid_refresh_token}
        end
    end
  end

  def cleanup_expired do
    cutoff = DateTime.utc_now() |> DateTime.add(-3600, :second)

    {auth_count, _} =
      from(da in DeviceAuthorization, where: da.expires_at < ^cutoff)
      |> Repo.delete_all(skip_tenant_check: true)

    revoke_cutoff = DateTime.utc_now() |> DateTime.add(-7 * 24 * 3600, :second)

    {token_count, _} =
      from(rt in DeviceRefreshToken,
        where: not is_nil(rt.revoked_at) and rt.revoked_at < ^revoke_cutoff
      )
      |> Repo.delete_all(skip_tenant_check: true)

    {auth_count + token_count, nil}
  end

  # ── Private ─────────────────────────────────────────────────────

  defp consume_and_issue_tokens(auth) do
    auth
    |> Ecto.Changeset.change(%{status: "consumed"})
    |> Repo.update!(skip_tenant_check: true)

    access_token = Accounts.generate_jwt(auth.user)
    {raw_refresh, _hash} = create_refresh_token(auth.user_id, auth.vault_id)

    {:ok,
     %{
       access_token: access_token,
       refresh_token: raw_refresh,
       vault_id: auth.vault_id,
       user_email: auth.user.email,
       expires_in: Engram.Token.ttl_seconds()
     }}
  end

  # Rotate the verified old token into a fresh one within its family, minting a
  # new access token. Inherits the old token's owner, so a token can only ever
  # mint tokens for its own user/vault.
  defp issue_child(old_token) do
    access_token = Accounts.generate_jwt(old_token.user)

    {raw_refresh, _hash} =
      create_refresh_token(old_token.user_id, old_token.vault_id, old_token.family_id)

    {:ok,
     %{
       access_token: access_token,
       refresh_token: raw_refresh,
       expires_in: Engram.Token.ttl_seconds()
     }}
  end

  # Reuse breach: hard-delete the entire family. Deleting (rather than stamping
  # revoked_at) is deliberate — a freshly-revoked current token would otherwise
  # fall inside the leeway window and be mistaken for a benign retry, defeating
  # the revocation. Scoped by family_id (owner-bound, a family never crosses
  # users), so only the compromised lineage is touched.
  defp invalidate_family(old_token) do
    Logger.warning(
      "device refresh-token reuse detected; revoking family " <>
        "family_id=#{old_token.family_id} user_id=#{old_token.user_id}"
    )

    from(rt in DeviceRefreshToken, where: rt.family_id == ^old_token.family_id)
    |> Repo.delete_all(skip_tenant_check: true)
  end

  # A nil family_id starts a new family (fresh login); rotation passes the old
  # token's family_id to keep the lineage together.
  defp create_refresh_token(user_id, vault_id, family_id \\ nil) do
    raw =
      @refresh_token_prefix <>
        Base.url_encode64(:crypto.strong_rand_bytes(@refresh_token_bytes), padding: false)

    token_hash = hash_token(raw)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(@refresh_token_ttl_days * 24 * 3600, :second)
      |> DateTime.truncate(:second)

    %DeviceRefreshToken{}
    |> DeviceRefreshToken.changeset(%{
      token_hash: token_hash,
      family_id: family_id || Ecto.UUID.generate(),
      user_id: user_id,
      vault_id: vault_id,
      expires_at: expires_at
    })
    |> Repo.insert!(skip_tenant_check: true)

    {raw, token_hash}
  end

  defp hash_token(raw) do
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end

  defp generate_user_code do
    part1 = for(_ <- 1..4, into: "", do: <<Enum.random(@user_code_chars)>>)
    part2 = for(_ <- 1..4, into: "", do: <<Enum.random(@user_code_chars)>>)
    "#{part1}-#{part2}"
  end
end
