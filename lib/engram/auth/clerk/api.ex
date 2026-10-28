defmodule Engram.Auth.Clerk.Api do
  @moduledoc """
  Behaviour over the Clerk Backend API. Used by webhook handlers when we
  need to revoke a Clerk user (e.g. multi-account farming dup-detect).
  Real implementation in `Engram.Auth.Clerk.HttpApi`; tests use a Mox.
  """

  @callback delete_user(clerk_user_id :: String.t()) ::
              :ok | {:error, term()}

  @doc """
  Whether the Clerk user still exists: `{:ok, false}` only on a 404, so a
  caller can treat `false` as proof the identity is gone. Every other outcome
  is an error, never a guess.
  """
  @callback user_exists?(clerk_user_id :: String.t()) :: {:ok, boolean()} | {:error, term()}

  @doc """
  The user's newest session activity, country level only (no IP, no city):
  `{:ok, %{country: "US" | nil, device_type: "mobile" | "desktop" | ... | nil}}`,
  or `{:ok, nil}` when Clerk has no session for them.
  """
  @callback latest_activity(clerk_user_id :: String.t()) ::
              {:ok, %{country: String.t() | nil, device_type: String.t() | nil} | nil}
              | {:error, term()}
end
