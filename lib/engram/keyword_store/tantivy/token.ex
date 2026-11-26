defmodule Engram.KeywordStore.Tantivy.Token do
  @moduledoc """
  Signed per-request tokens for the kwsearch service (security F7, F14).

  `b64url(payload_json) <> "." <> b64url(HMAC-SHA256(key, b64url(payload_json)))`,
  unpadded. A search token names the user and the vaults the request may
  read, so kwsearch takes the tenant from the signature, never from the body:
  `%{"s" => "search", "u" => user_id, "v" => [vault_id], "exp" => unix_s}`.
  A bulk token (`%{"s" => "bulk", "u" => user_id, "exp" => unix_s}`) writes
  and lists ONE user's docs (backfill, reconcile), the user again taken from
  the signature. An ops token (`%{"s" => "ops", "exp" => unix_s}`) reads the
  applied cursor and reports a finished rebuild.

  Keys rotate by overlap: `sign/2` uses the first configured key, and a token
  verifies against ANY listed key, so the list is `[current, next]` during a
  rotation and `[next]` once the old one is retired. kwsearch implements the
  same check (`native/kwsearch`); `verify/3` here pins the format in tests.
  """

  # kwsearch refuses an exp further out than this; a request token lives 60 s.
  @max_ahead_s 300
  @ttl_s 60

  @spec sign(map(), binary()) :: String.t()
  def sign(payload, key) when is_map(payload) and is_binary(key) do
    body = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
    body <> "." <> Base.url_encode64(mac(key, body), padding: false)
  end

  @doc "A search token for `user_id` over `vault_ids`, valid #{@ttl_s} s."
  @spec search(String.t(), [String.t()], binary(), integer()) :: String.t()
  def search(user_id, vault_ids, key, now \\ System.system_time(:second)),
    do: sign(%{"s" => "search", "u" => user_id, "v" => vault_ids, "exp" => now + @ttl_s}, key)

  @doc "A bulk token for `user_id` (backfill, reconcile), valid #{@ttl_s} s."
  @spec bulk(String.t(), binary(), integer()) :: String.t()
  def bulk(user_id, key, now \\ System.system_time(:second)),
    do: sign(%{"s" => "bulk", "u" => user_id, "exp" => now + @ttl_s}, key)

  @doc "An ops token (the feed trim's cursor read), valid #{@ttl_s} s."
  @spec ops(binary(), integer()) :: String.t()
  def ops(key, now \\ System.system_time(:second)),
    do: sign(%{"s" => "ops", "exp" => now + @ttl_s}, key)

  @doc "The payload when some key in `keys` signed `token` and it has not expired."
  @spec verify(String.t(), [binary()], integer()) :: {:ok, map()} | :error
  def verify(token, keys, now \\ System.system_time(:second)) do
    with [body, sig] <- String.split(token, ".", parts: 2),
         {:ok, sig} <- Base.url_decode64(sig, padding: false),
         true <- Enum.any?(keys, &Plug.Crypto.secure_compare(mac(&1, body), sig)),
         {:ok, json} <- Base.url_decode64(body, padding: false),
         {:ok, %{"exp" => exp} = payload} when is_integer(exp) <- Jason.decode(json),
         true <- exp >= now and exp <= now + @max_ahead_s do
      {:ok, payload}
    else
      _ -> :error
    end
  end

  defp mac(key, body), do: :crypto.mac(:hmac, :sha256, key, body)
end
