defmodule Engram.Webhooks.Svix do
  @moduledoc """
  Verification for Svix-signed webhooks (used by Clerk and Resend).

  Svix signs `"\#{id}.\#{timestamp}.\#{payload}"` with HMAC-SHA256 using the
  base64-decoded `whsec_`-prefixed secret, base64-encodes the result, and sends
  it in the `svix-signature` header as space-separated `v1,<sig>` entries.
  Stale timestamps are rejected to prevent replay.
  """

  @max_age_seconds 300

  @doc """
  Verify a Svix-signed webhook. `secret` is the raw `whsec_...` string from the
  provider dashboard. Returns `:ok` or `{:error, reason}`.
  """
  @spec verify(String.t(), String.t(), binary(), String.t(), String.t() | nil, keyword()) ::
          :ok | {:error, String.t()}
  def verify(id, timestamp, payload, sig_header, secret, opts \\ []) do
    max_age = Keyword.get(opts, :max_age_seconds, @max_age_seconds)

    with :ok <- check_age(timestamp, max_age),
         {:ok, secret_bytes} <- decode_secret(secret) do
      expected =
        :crypto.mac(:hmac, :sha256, secret_bytes, "#{id}.#{timestamp}.#{payload}")
        |> Base.encode64()

      sig_header
      |> String.split(" ", trim: true)
      |> Enum.map(&strip_v1_prefix/1)
      |> Enum.any?(&Plug.Crypto.secure_compare(&1, expected))
      |> case do
        true -> :ok
        false -> {:error, "invalid signature"}
      end
    end
  end

  defp check_age(timestamp_str, max_age) do
    case Integer.parse(to_string(timestamp_str)) do
      {ts, _} ->
        if abs(System.system_time(:second) - ts) <= max_age,
          do: :ok,
          else: {:error, "timestamp too old"}

      :error ->
        {:error, "invalid timestamp"}
    end
  end

  defp decode_secret(nil), do: {:error, "webhook secret not configured"}
  defp decode_secret(""), do: {:error, "webhook secret not configured"}

  defp decode_secret(secret) when is_binary(secret) do
    secret
    |> String.replace_prefix("whsec_", "")
    |> Base.decode64()
    |> case do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, "webhook secret malformed"}
    end
  end

  defp strip_v1_prefix("v1," <> sig), do: sig
  defp strip_v1_prefix(_), do: ""
end
