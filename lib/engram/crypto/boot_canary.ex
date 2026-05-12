defmodule Engram.Crypto.BootCanary do
  @moduledoc """
  T3.5.5 / M3 — boot canary for the master encryption key (provider-polymorphic).

  At application boot:

  1. Resolves the active `KeyProvider` (Local | AwsKms).
  2. Calls `provider.boot_check/0` — for AwsKms this issues a `DescribeKey`
     against the configured CMK, surfacing wrong-ARN, IAM-denied, or
     wrong-region misconfiguration before the first user request hits the
     hot path. For Local this is a no-op.
  3. Looks up the most-recent canary row and unwraps via
     `provider.unwrap_dek_no_fallback/2`. Local refuses to consult its
     `_PREVIOUS` slot so a misconfigured `ENCRYPTION_MASTER_KEY` cannot be
     silently rescued. AwsKms has no fallback concept and delegates to
     `unwrap_dek/2`.
  4. Hashes the plaintext and compares against the stored SHA256.

  Emits `[:engram, :crypto, :boot_canary]` with `provider:` metadata on
  every outcome. Boot fails loudly on any unwrap or SHA mismatch.
  """

  import Ecto.Query, only: [from: 2]

  alias Engram.Crypto.KeyProvider.Resolver
  alias Engram.Repo

  require Logger

  @canary_dek_size 32
  # sentinel — system_canaries has no FK to users; reserved out-of-band from normal user IDs
  @canary_user_id 0

  @doc """
  Verify the boot canary against the configured KeyProvider. Idempotent.
  Provisions a fresh canary if none exists.
  """
  @spec verify!() :: :ok
  def verify! do
    provider = Resolver.provider()
    :ok = ensure_provider_ready!(provider)

    case fetch_latest() do
      nil ->
        Logger.warning("boot_canary: no canary row, provisioning fresh",
          category: :boot_canary
        )

        provision!(provider)

        :telemetry.execute(
          [:engram, :crypto, :boot_canary],
          %{count: 1},
          %{status: :provisioned, provider: provider.name()}
        )

        :ok

      %{wrapped_dek: blob, dek_sha256: expected_hash} ->
        case provider.unwrap_dek_no_fallback(blob, %{user_id: @canary_user_id}) do
          {:ok, plaintext_dek} ->
            verify_sha!(plaintext_dek, expected_hash, provider)

          {:error, reason} ->
            :telemetry.execute(
              [:engram, :crypto, :boot_canary],
              %{count: 1},
              %{
                status: :failed,
                provider: provider.name(),
                reason_label: reason_label(reason)
              }
            )

            raise """
            boot canary unwrap failed: #{inspect(reason)} via provider #{provider.name()}.
            Verify env vars and re-run rotation if a master-key cutover is in
            progress.
            """
        end
    end
  end

  defp ensure_provider_ready!(provider) do
    case provider.boot_check() do
      :ok ->
        :ok

      {:error, reason} ->
        :telemetry.execute(
          [:engram, :crypto, :boot_canary],
          %{count: 1},
          %{
            status: :failed,
            provider: provider.name(),
            reason_label: reason_label(reason)
          }
        )

        raise """
        boot_check failed for provider #{provider.name()}: #{inspect(reason)}.
        Verify the configured key provider is reachable and the credentials /
        IAM policy permit DescribeKey on the configured CMK.
        """
    end
  end

  defp verify_sha!(plaintext_dek, expected_hash, provider) do
    if :crypto.hash(:sha256, plaintext_dek) == expected_hash do
      :telemetry.execute(
        [:engram, :crypto, :boot_canary],
        %{count: 1},
        %{status: :ok, provider: provider.name()}
      )

      :ok
    else
      :telemetry.execute(
        [:engram, :crypto, :boot_canary],
        %{count: 1},
        %{
          status: :failed,
          provider: provider.name(),
          reason_label: "sha_mismatch"
        }
      )

      raise """
      boot canary unwrap returned a plaintext that does not match the recorded
      SHA256. This indicates a corrupted canary row, not a wrong-key situation.
      Inspect the system_canaries table.
      """
    end
  end

  @doc """
  Provision a fresh canary row using the active provider. Used by:

  * Boot, when the table is empty.
  * `MasterRotation.rotate_canary/0` after rotating the user fleet.
  """
  @spec provision!(module()) :: :ok
  def provision!(provider \\ Resolver.provider()) do
    dek = :crypto.strong_rand_bytes(@canary_dek_size)
    {:ok, wrapped} = provider.wrap_dek(dek, %{user_id: @canary_user_id})
    sha = :crypto.hash(:sha256, dek)
    now = DateTime.utc_now()

    {1, _} =
      Repo.insert_all(
        "system_canaries",
        [
          %{
            wrapped_dek: wrapped,
            dek_sha256: sha,
            inserted_at: now,
            updated_at: now
          }
        ]
      )

    :ok
  end

  # Order by `id` (BIGSERIAL) instead of `inserted_at` — id is monotonic
  # regardless of clock skew or NTP step-back, so a fresh canary is
  # always the highest id. Avoids the failure mode where a backwards
  # clock jump makes a NEW row's `inserted_at` < OLD row's, masking
  # the new row from boot verification.
  defp fetch_latest do
    Repo.one(
      from c in "system_canaries",
        order_by: [desc: c.id],
        limit: 1,
        select: %{wrapped_dek: c.wrapped_dek, dek_sha256: c.dek_sha256}
    )
  end

  defp reason_label(:invalid_wrapping), do: "invalid_wrapping"
  defp reason_label(:malformed_wrapped_blob), do: "malformed_wrapped_blob"
  defp reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_label(reason), do: inspect(reason)
end
