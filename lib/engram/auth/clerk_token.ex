defmodule Engram.Auth.ClerkToken do
  @moduledoc """
  Verifies Clerk JWTs using JWKS-fetched public keys.

  Uses joken_jwks to automatically fetch and cache Clerk's public signing keys.
  Validates: signature (RS256 via JWKS), expiry, not-before, issuer, and
  (when configured) the `azp` (Authorized Party) claim against an allowlist.
  """

  use Joken.Config

  add_hook(JokenJwks, strategy: Engram.Auth.ClerkStrategy)

  @impl true
  def token_config do
    default_claims(skip: [:aud, :jti, :iss])
    |> add_claim("iss", nil, &validate_issuer/1)
  end

  defp validate_issuer(issuer) do
    expected = Application.get_env(:engram, :clerk_issuer)
    issuer == expected
  end

  @doc """
  Verifies a Clerk JWT and returns `{:ok, claims}` or `{:error, reason}`.
  """
  def verify_clerk_jwt(token) do
    with {:ok, claims} <- verify_and_validate(token),
         :ok <- validate_authorized_party(claims) do
      {:ok, claims}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  # Mirrors @clerk/backend's `assertAuthorizedPartiesClaim`: empty allowlist
  # is passthrough; otherwise the `azp` claim must be present and a member.
  defp validate_authorized_party(claims) do
    case Application.get_env(:engram, :clerk_authorized_parties, []) do
      [] ->
        :ok

      parties when is_list(parties) ->
        case Map.get(claims, "azp") do
          azp when is_binary(azp) ->
            if azp in parties, do: :ok, else: {:error, :invalid_azp}

          _ ->
            {:error, :invalid_azp}
        end
    end
  end
end
