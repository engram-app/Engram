defmodule Engram.Auth.TokenDebug do
  @moduledoc """
  Best-effort, NON-verifying peek at a token's header + claims, for attributing
  auth rejections in logs. Never raises, never verifies a signature, never logs
  raw sub.

  `sub_hash` uses the same keyed `Engram.Crypto.HMAC.hash_user_id/1` helper as
  the `user_id` log metadata in `Engram.Logs`, `UserSocket`, `SyncChannel`, and
  `CRDTChannel`. For internal JWTs, `sub` is our own `users.id`, so hashing it
  with the same key produces the same hash used everywhere else, letting a
  rejected internal-JWT `sub` correlate to that user's other log lines.
  """

  @spec metadata(String.t()) :: keyword()
  def metadata(token) when is_binary(token) do
    header = safe_peek(&Joken.peek_header/1, token)
    claims = safe_peek(&Joken.peek_claims/1, token)

    [
      alg: header["alg"],
      kid: header["kid"],
      iss: claims["iss"],
      # `iat`/`exp` are unix epochs, not PII. They discriminate the two causes
      # of a sustained socket-reject loop that otherwise look identical: a FROZEN
      # `iat` (unchanged across every reject) means the client is replaying one
      # token and never calling getToken; an ADVANCING `iat` on a
      # `signature_error` means fresh tokens are being minted that still fail
      # verify — i.e. signing-key / JWKS drift, not a stuck client.
      iat: claims["iat"],
      exp: claims["exp"],
      sub_hash: hash_sub(claims["sub"])
    ]
  end

  def metadata(_), do: [alg: nil, kid: nil, iss: nil, iat: nil, exp: nil, sub_hash: nil]

  defp safe_peek(fun, token) do
    case fun.(token) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp hash_sub(sub) when is_binary(sub), do: Engram.Crypto.HMAC.hash_user_id(sub)
  defp hash_sub(_), do: nil
end
