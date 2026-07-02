defmodule Engram.Idempotency do
  @moduledoc """
  Postgres-backed idempotency-key store for batch endpoints (#862).

  The previous ETS cache was node-local: under clustering, a client retry
  routed to the other node missed the cache and re-executed the batch — the
  idempotency key was defeated by the load balancer. It was also keyed
  globally rather than per user. Rows here are user-scoped (lookup requires
  the authenticated user) and the cached response body is encrypted under
  the user's DEK with the AAD bound to `(user_id, key)` — batch responses
  carry plaintext note paths, which never sit plaintext at rest anywhere
  else.

  Decrypt failure degrades to `:miss` by design: after a per-user DEK
  rotation (T3.7) old rows are unreadable, and re-executing the batch is
  safe — identical-content upserts short-circuit (#860), so a replayed
  batch converges on the same result.

  Expiry: rows past `expires_at` (default TTL 24h) read as `:miss`
  immediately and are deleted by the daily `IdempotencyPrune` worker.
  """

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Idempotency.Key
  alias Engram.Repo

  require Logger

  @default_ttl_ms 24 * 60 * 60 * 1000

  @spec remember(map(), Ecto.UUID.t(), %{status: integer(), body: term()}, keyword()) :: :ok
  def remember(user, key, %{status: status, body: body}, opts \\ []) do
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    expires_at = DateTime.add(DateTime.utc_now(), ttl_ms, :millisecond)

    case Crypto.get_dek(user) do
      {:ok, dek} ->
        {ciphertext, nonce} = Envelope.encrypt(Jason.encode!(body), dek, aad(user.id, key))

        {:ok, _} =
          Repo.with_tenant(user.id, fn ->
            Repo.insert_all(
              Key,
              [
                %{
                  id: Ecto.UUID.generate(),
                  user_id: user.id,
                  key: key,
                  status: status,
                  response_ciphertext: ciphertext,
                  response_nonce: nonce,
                  expires_at: expires_at,
                  inserted_at: DateTime.utc_now()
                }
              ],
              # First response wins — a concurrent duplicate remember no-ops.
              on_conflict: :nothing,
              conflict_target: [:user_id, :key]
            )
          end)

        :ok

      {:error, _} ->
        # No DEK → nothing to cache. A future replay degrades to
        # re-execution, which is safe (idempotent upserts short-circuit).
        :ok
    end
  end

  @spec lookup(map(), Ecto.UUID.t()) :: {:ok, %{status: integer(), body: term()}} | :miss
  def lookup(user, key) do
    now = DateTime.utc_now()

    {:ok, row} =
      Repo.with_tenant(user.id, fn ->
        Repo.one(
          from(k in Key,
            where: k.user_id == ^user.id and k.key == ^key and k.expires_at > ^now
          )
        )
      end)

    with %Key{} <- row,
         {:ok, dek} <- Crypto.get_dek(user),
         {:ok, json} <-
           decrypt_response(row.response_ciphertext, row.response_nonce, dek, user.id, key) do
      {:ok, %{status: row.status, body: Jason.decode!(json)}}
    else
      _ -> :miss
    end
  end

  @doc """
  Deletes expired rows across all users. Cross-tenant by design (the table
  relies on app-layer scoping — see the rls_coverage allowlist); called by
  the daily `Engram.Workers.IdempotencyPrune` cron.
  """
  @spec prune_expired() :: {:ok, non_neg_integer()}
  def prune_expired do
    {count, _} =
      Repo.delete_all(
        from(k in Key, where: k.expires_at <= ^DateTime.utc_now()),
        skip_tenant_check: true
      )

    {:ok, count}
  end

  defp decrypt_response(ciphertext, nonce, dek, user_id, key) do
    case Envelope.decrypt(ciphertext, nonce, dek, aad(user_id, key)) do
      {:ok, json} ->
        {:ok, json}

      :error ->
        # Expected after a per-user DEK rotation — replay-by-re-execution is
        # safe (idempotent upserts short-circuit), so degrade to :miss.
        Logger.warning(
          "idempotency_response_undecryptable",
          Engram.Logger.Metadata.with_category(:warning, :crypto, user_id: user_id)
        )

        :miss
    end
  end

  defp aad(user_id, key), do: "idempotency_keys:response:#{user_id}:#{key}"
end
