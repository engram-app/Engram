defmodule Engram.Token do
  @moduledoc """
  Joken JWT config for Engram-issued access tokens.

  Defines the `iss`/`aud` required-claim hooks and the access-token lifetime
  used by both the JWT `exp` claim and the `expires_in` response field.
  """

  use Joken.Config

  # Single source of truth for access-token lifetime. Used both as the JWT
  # `exp` claim duration and as the `expires_in` field returned to clients —
  # keeping these in sync is required for clients to refresh on time.
  @ttl_seconds 15 * 60

  add_hook(Joken.Hooks.RequiredClaims, ["iss", "aud"])

  @doc "Access-token lifetime in seconds."
  def ttl_seconds, do: @ttl_seconds

  @impl true
  def token_config do
    # skip: [:iss, :aud] prevents Joken from auto-generating default iss/aud claims
    # that would conflict with our explicit add_claim registrations below.
    # Without skip, Joken would try to register its own iss/aud generators and the
    # duplicate key definitions would raise a runtime error.
    default_claims(default_exp: @ttl_seconds, skip: [:iss, :aud])
    |> add_claim("iss", fn -> "engram" end, &(&1 == "engram"))
    |> add_claim("aud", fn -> "engram" end, &(&1 == "engram"))
  end
end
