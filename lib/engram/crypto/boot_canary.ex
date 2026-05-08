defmodule Engram.Crypto.BootCanary do
  @moduledoc """
  T3.5.5 / M3 — boot canary for the master encryption key.

  At application boot, attempts to unwrap the most recent canary row's
  `wrapped_dek` using ONLY the current master key (no `_PREVIOUS`
  fallback). Two outcomes:

  * **No canary row yet** — provisions a fresh canary with the current
    master key and logs a warning. Subsequent boots will verify against
    this row.
  * **Unwrap succeeds + plaintext SHA matches** — emits
    `[:engram, :crypto, :boot_canary]` with `status: :ok`.
  * **Unwrap fails OR plaintext SHA mismatch** — raises. Boot stops.

  This catches the silent failure mode where an operator points the app
  at the wrong `ENCRYPTION_MASTER_KEY`: with `_PREVIOUS` set, every
  in-flight unwrap quietly falls back to the previous key, the app keeps
  serving, but newly-written wraps are produced with the wrong key. The
  canary's no-fallback unwrap detects this immediately at boot.

  Updated by `Engram.Crypto.MasterRotation.rotate_canary/0` after the
  user fleet has been rotated. Operators who skip the canary update will
  see the next boot fail loudly — which is the desired behavior.

  ## Failure mode reference

      RuntimeError: boot canary unwrap failed: :invalid_wrapping.
      Current ENCRYPTION_MASTER_KEY does not match the key used to
      wrap the most recent canary. Verify env vars and re-run rotation
      if a master-key cutover is in progress.
  """

  import Ecto.Query, only: [from: 2]
  require Logger

  alias Engram.Crypto.KeyProvider.Local
  alias Engram.Repo

  @canary_dek_size 32

  @doc """
  Verify the boot canary against the current master key. Idempotent.
  Provisions a fresh canary if none exists.
  """
  @spec verify!() :: :ok
  def verify! do
    case fetch_latest() do
      nil ->
        Logger.warning("boot_canary: no canary row, provisioning fresh", category: :boot_canary)
        provision!()
        :telemetry.execute([:engram, :crypto, :boot_canary], %{count: 1}, %{status: :provisioned})
        :ok

      %{wrapped_dek: blob, dek_sha256: expected_hash} ->
        case Local.unwrap_dek_current_only(blob) do
          {:ok, plaintext_dek} ->
            if :crypto.hash(:sha256, plaintext_dek) == expected_hash do
              :telemetry.execute([:engram, :crypto, :boot_canary], %{count: 1}, %{status: :ok})
              :ok
            else
              :telemetry.execute(
                [:engram, :crypto, :boot_canary],
                %{count: 1},
                %{status: :failed, reason_label: "sha_mismatch"}
              )

              raise """
              boot canary unwrap returned a plaintext that does not match the
              recorded SHA256. This indicates a corrupted canary row, not a
              wrong-key situation. Inspect the system_canaries table.
              """
            end

          {:error, reason} ->
            :telemetry.execute(
              [:engram, :crypto, :boot_canary],
              %{count: 1},
              %{status: :failed, reason_label: reason_label(reason)}
            )

            raise """
            boot canary unwrap failed: #{inspect(reason)}.
            Current ENCRYPTION_MASTER_KEY does not match the key used to wrap
            the most recent canary. Verify env vars and re-run rotation if a
            master-key cutover is in progress.
            """
        end
    end
  end

  @doc """
  Provision a fresh canary row using the current master key. Used by:

  * Boot, when the table is empty.
  * `MasterRotation.rotate_canary/0` after rotating the user fleet.
  """
  @spec provision!() :: :ok
  def provision! do
    dek = :crypto.strong_rand_bytes(@canary_dek_size)
    {:ok, wrapped} = Local.wrap_dek(dek, %{user_id: :canary})
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
  defp reason_label(_), do: "other"
end
