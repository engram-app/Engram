defmodule Engram.Logger.DecryptFailure do
  @moduledoc """
  Single, safe entry point for logging a decryption failure.

  Decrypt failures are top-priority emergency signals (persisted ciphertext
  that won't decrypt means real data corruption), so the log line must carry
  enough context for an operator to triage — `user_id`, `note_id` — as
  structured metadata, queryable by label in Loki/Sentry rather than buried in
  an interpolated message string.

  **Security invariant:** the raw `reason` never enters the message body or the
  metadata. A decrypt failure bubbles up Req/Postgrex/crypto error terms that
  can wrap secrets (tokens, passwords, bound params), and the message body is
  past the reach of `Engram.Logger.RedactFilter`. Only a bounded
  `error_kind` atom from `Engram.Telemetry.error_kind/1` is allowed to escape.
  """

  alias Engram.Telemetry

  require Logger

  @doc """
  Emit an `:error`-level decrypt-failure log.

  `metadata` holds the safe identifiers (e.g. `user_id:`, `note_id:`). The
  bounded `error_kind` derived from `reason` is appended automatically.
  """
  @spec log(String.t(), term(), keyword()) :: :ok
  def log(message, reason, metadata \\ [])
      when is_binary(message) and is_list(metadata) do
    Logger.error(message, Keyword.put(metadata, :error_kind, Telemetry.error_kind(reason)))
  end
end
