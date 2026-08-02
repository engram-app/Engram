defmodule Engram.Auth.Providers.Claims do
  @moduledoc """
  Shared claim-shape handling for token-verifying auth providers.

  Clerk (RS256 via JWKS) and Local (HS256) verify tokens differently, but
  both must extract the same `{sub, email}` identity shape from the claims.
  Keeping the extraction here means the two providers can't drift on what
  counts as a complete identity (e.g. one accepting an empty email).
  """

  @typedoc "Provider identity extracted from verified JWT claims."
  @type identity :: %{external_id: String.t(), email: String.t()}

  @doc """
  Maps a verify-call result into the provider identity.

  `sub` must be a binary and `email` a non-empty binary; anything else is
  `{:error, :missing_claims}`. Verify errors pass through unchanged.
  """
  @spec to_identity({:ok, map()} | {:error, term()}) :: {:ok, identity()} | {:error, term()}
  def to_identity({:ok, claims}) do
    case {claims["sub"], claims["email"]} do
      {ext_id, email} when is_binary(ext_id) and is_binary(email) and email != "" ->
        {:ok, %{external_id: ext_id, email: email}}

      _ ->
        {:error, :missing_claims}
    end
  end

  def to_identity({:error, reason}), do: {:error, reason}
end
