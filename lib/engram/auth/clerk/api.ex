defmodule Engram.Auth.Clerk.Api do
  @moduledoc """
  Behaviour over the Clerk Backend API. Used by webhook handlers when we
  need to revoke a Clerk user (e.g. multi-account farming dup-detect).
  Real implementation in `Engram.Auth.Clerk.HttpApi`; tests use a Mox.
  """

  @callback delete_user(clerk_user_id :: String.t()) ::
              :ok | {:error, term()}
end
