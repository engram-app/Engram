defmodule Engram.Auth.TokenDebug do
  @moduledoc """
  Best-effort, NON-verifying peek at a token's header + claims, for attributing
  auth rejections in logs. Never raises, never verifies a signature, never logs
  raw sub (hashed with sha256-hex).

  The sha256 hash here is intentionally NOT the keyed `Engram.Crypto.HMAC.hash_user_id/1`
  used elsewhere for our internal `users.id`: this module hashes the JWT `sub`
  claim from an as-yet-unverified, possibly-rejected token, which may be an
  external issuer's subject id (Clerk, device flow, etc), not our own user id.
  Reusing the keyed helper would conflate two different id spaces under one
  key. Plain sha256-hex still gives stable, joinable, non-reversible labels
  for correlating repeated rejections from the same presented token.
  """

  @spec metadata(String.t()) :: keyword()
  def metadata(token) when is_binary(token) do
    header = safe_peek(&Joken.peek_header/1, token)
    claims = safe_peek(&Joken.peek_claims/1, token)

    [
      alg: header["alg"],
      kid: header["kid"],
      iss: claims["iss"],
      sub_hash: hash_sub(claims["sub"])
    ]
  end

  def metadata(_), do: [alg: nil, kid: nil, iss: nil, sub_hash: nil]

  defp safe_peek(fun, token) do
    case fun.(token) do
      {:ok, map} -> map
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp hash_sub(nil), do: nil
  defp hash_sub(sub), do: :crypto.hash(:sha256, sub) |> Base.encode16(case: :lower)
end
