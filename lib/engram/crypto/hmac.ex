defmodule Engram.Crypto.HMAC do
  @moduledoc """
  Stable hashing for use in telemetry, logs, and other low-trust observability
  surfaces where the raw `user_id` must not leak.

  Distinct from per-user filter keys (`Engram.Crypto.dek_filter_key/1`) and
  domain HMAC subkeys used inside the encryption envelope — this module's
  key is a single global secret used only to obscure user identifiers in
  metric labels and log lines.
  """

  @doc """
  Stable hex HMAC of a user id, for use in telemetry / logs.

  Same input → same output, so metric labels remain joinable across events.
  The key is loaded from `Application.fetch_env!(:engram, :hmac_key_user_id)`
  — set per environment. In tests + dev, a fixed throwaway key is fine; in
  prod it MUST be a high-entropy secret distinct from any encryption key.
  """
  # `users.id` is `bigserial` (integer) in this repo — see the comment in
  # `priv/repo/migrations/20260603000010_create_onboarding_actions.exs`. The
  # integer-only guard is intentional: a binary input here would mean a caller
  # passed something other than a user PK, and we want that to fail loudly
  # rather than silently hash the wrong value.
  @spec hash_user_id(integer()) :: String.t()
  def hash_user_id(user_id) when is_integer(user_id) do
    key = Application.fetch_env!(:engram, :hmac_key_user_id)

    :crypto.mac(:hmac, :sha256, key, Integer.to_string(user_id))
    |> Base.encode16(case: :lower)
  end
end
