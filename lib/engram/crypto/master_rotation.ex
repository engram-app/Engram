defmodule Engram.Crypto.MasterRotation do
  @moduledoc """
  Per-user master-key rotation. Rewraps `users.encrypted_dek` with the
  current master key (via `KeyProvider.rotate_wrapping/2`) and bumps
  `users.dek_version`.

  Idempotent — `rotate_user/2` skips users already at target_version.
  Telemetry: `[:engram, :crypto, :rotate, :user]` per call with
  `%{duration_us: integer}` measurements and
  `%{user_id, status: :ok | :skipped | :failed, reason_label?}` metadata.

  ## When to use

  Triggered after operations rotates `ENCRYPTION_MASTER_KEY`:

      ENCRYPTION_MASTER_KEY=<NEW>
      ENCRYPTION_MASTER_KEY_PREVIOUS=<OLD>

  Then run `mix engram.rotate_master_key --target-version 2` (dev / staging)
  or enqueue `Engram.Workers.RotateUserMasterKey` jobs (production). Once
  every user has rotated, `SELECT MIN(dek_version) FROM users` ≥ target,
  it is safe to drop `_PREVIOUS` from environment.

  ## Lock + transaction shape

  Each per-user rotation runs in its own `Repo.transaction` with
  `SELECT ... FOR UPDATE` on the user row. Concurrent callers (Mix task +
  Oban job for the same user, or two Oban jobs) serialize cleanly: the
  loser sees the new `dek_version` post-commit and short-circuits to the
  `:skipped` path.

  Locks scope to the per-user transaction — no lock accumulation across
  the whole user fleet. Streaming is cursor-by-id outside the txn.
  """

  import Ecto.Query, only: [from: 2]

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Crypto.KeyProvider.Resolver
  alias Engram.Repo

  require Logger

  @typedoc "`:ok` on rewrap, `:skipped` on no-op, `{:error, term}` on failure."
  @type rotate_result :: :ok | :skipped | {:error, term()}

  @typedoc "Aggregate from streaming over the user fleet."
  @type counts :: %{ok: non_neg_integer(), skipped: non_neg_integer(), failed: non_neg_integer()}

  @doc """
  Rotate one user's wrapped DEK to `target_version`.

  Returns `:ok` on rewrap, `:skipped` if user.dek_version is already
  ≥ target, `{:error, reason}` otherwise.
  """
  @spec rotate_user(String.t() | User.t(), pos_integer()) :: rotate_result()
  def rotate_user(user_or_id, target_version)
      when is_integer(target_version) and target_version >= 1 do
    user_id =
      case user_or_id do
        %User{id: id} -> id
        id when is_binary(id) -> id
      end

    started_at = System.monotonic_time()
    result = do_rotate(user_id, target_version)
    duration_us = duration_us_since(started_at)
    emit_telemetry(user_id, result, duration_us)

    case result do
      {:rotated, _} -> :ok
      {:skipped, _} -> :skipped
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Rotate every user whose `dek_version < target_version`. Cursor-driven
  by `id` order. Each user runs in its own transaction.

  Options:

    * `:batch_size` — rows fetched per cursor page (default 100). The
      loop terminates when the page returns empty.

  Returns the aggregate `counts` map.
  """
  @spec rotate_all(pos_integer(), keyword()) :: counts() | {:error, term()}
  def rotate_all(target_version, opts \\ [])
      when is_integer(target_version) and target_version >= 1 do
    batch_size = Keyword.get(opts, :batch_size, 100)

    drive_loop(
      target_version,
      "00000000-0000-0000-0000-000000000000",
      batch_size,
      %{ok: 0, skipped: 0, failed: 0}
    )
  end

  @doc """
  Rotate the boot canary row. Provisions a new canary with the current
  master key. Always run AFTER the user fleet has rotated successfully —
  if you rotate the canary first and the user rotation fails, the canary
  will mask the failure on subsequent boots.
  """
  @spec rotate_canary() :: :ok
  def rotate_canary do
    Engram.Crypto.BootCanary.provision!()
  end

  @doc """
  Enqueues one `Engram.Workers.RotateUserMasterKey` job per below-target
  user. Returns the count of jobs inserted. Production-friendly variant
  of `rotate_all/2` — survives node restarts and offloads pacing to
  Oban's `:crypto_backfill` queue concurrency cap.

  Idempotent: the worker's uniqueness key (`[:user_id, :target_version]`)
  collapses duplicate inserts; users already at target are skipped at
  perform-time.
  """
  @spec enqueue_all(pos_integer(), keyword()) :: %{enqueued: non_neg_integer()}
  def enqueue_all(target_version, opts \\ [])
      when is_integer(target_version) and target_version >= 1 do
    batch_size = Keyword.get(opts, :batch_size, 500)

    %{
      enqueued:
        enqueue_loop(
          target_version,
          "00000000-0000-0000-0000-000000000000",
          batch_size,
          0
        )
    }
  end

  defp enqueue_loop(target_version, last_id, batch_size, total) do
    ids =
      from(u in User,
        where: not is_nil(u.encrypted_dek) and u.dek_version < ^target_version,
        where: u.id > ^last_id,
        select: u.id,
        order_by: u.id,
        limit: ^batch_size
      )
      |> Repo.all(skip_tenant_check: true)

    case ids do
      [] ->
        total

      _ ->
        jobs =
          Enum.map(ids, fn id ->
            Engram.Workers.RotateUserMasterKey.new(%{
              "user_id" => id,
              "target_version" => target_version
            })
          end)

        {:ok, _multi_result} =
          Ecto.Multi.new()
          |> Oban.insert_all(:rotate_jobs, jobs)
          |> Repo.transaction()

        enqueue_loop(target_version, List.last(ids), batch_size, total + length(jobs))
    end
  end

  # ── internals ───────────────────────────────────────────────────────

  defp do_rotate(user_id, target_version) do
    txn =
      Repo.transaction(fn ->
        locked =
          from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE")
          |> Repo.one(skip_tenant_check: true)

        cond do
          is_nil(locked) ->
            Repo.rollback({:not_found, user_id})

          is_nil(locked.encrypted_dek) ->
            Repo.rollback(:no_dek)

          locked.dek_version >= target_version ->
            {:skipped, locked}

          true ->
            rewrap_locked(locked, target_version)
        end
      end)

    case txn do
      {:ok, {:skipped, user}} -> {:skipped, user}
      {:ok, {:rotated, user}} -> {:rotated, user}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rewrap_locked(%User{} = locked, target_version) do
    provider = Resolver.provider_for(locked.id)

    case provider.rotate_wrapping(locked.encrypted_dek, %{user_id: locked.id}) do
      {:ok, new_wrapped} ->
        case Accounts.update_user_encryption(locked, %{
               encrypted_dek: new_wrapped,
               dek_version: target_version,
               key_provider: locked.key_provider
             }) do
          {:ok, updated} -> {:rotated, updated}
          {:error, changeset} -> Repo.rollback(changeset)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp drive_loop(target_version, last_id, batch_size, acc) do
    ids =
      from(u in User,
        where: not is_nil(u.encrypted_dek) and u.dek_version < ^target_version,
        where: u.id > ^last_id,
        select: u.id,
        order_by: u.id,
        limit: ^batch_size
      )
      |> Repo.all(skip_tenant_check: true)

    case ids do
      [] ->
        acc

      _ ->
        acc =
          Enum.reduce(ids, acc, fn id, a ->
            case rotate_user(id, target_version) do
              :ok -> Map.update!(a, :ok, &(&1 + 1))
              :skipped -> Map.update!(a, :skipped, &(&1 + 1))
              {:error, _} -> Map.update!(a, :failed, &(&1 + 1))
            end
          end)

        drive_loop(target_version, List.last(ids), batch_size, acc)
    end
  end

  defp duration_us_since(started_at) do
    System.convert_time_unit(
      System.monotonic_time() - started_at,
      :native,
      :microsecond
    )
  end

  defp emit_telemetry(user_id, {:rotated, _}, duration_us) do
    :telemetry.execute(
      [:engram, :crypto, :rotate, :user],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, status: :ok}
    )
  end

  defp emit_telemetry(user_id, {:skipped, _}, duration_us) do
    :telemetry.execute(
      [:engram, :crypto, :rotate, :user],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, status: :skipped}
    )
  end

  defp emit_telemetry(user_id, {:error, reason}, duration_us) do
    label = classify_reason(reason)

    # T3-audit H4 — telemetry alone is invisible during a master-key
    # cutover (until H2's metrics are scraped, and even then operators
    # need user-level triage). Logger.error guarantees the failed user
    # appears in any standard log pipeline so a stuck rotation is
    # diagnosable, not just countable.
    Logger.error(
      "master rotation failed user_id=#{user_id} reason_label=#{label}",
      category: :crypto_rotation
    )

    :telemetry.execute(
      [:engram, :crypto, :rotate, :user],
      %{duration_us: duration_us, count: 1},
      %{user_id: user_id, status: :failed, reason_label: label}
    )
  end

  defp classify_reason(:no_dek), do: "no_dek"
  defp classify_reason({:not_found, _}), do: "not_found"
  defp classify_reason(:invalid_wrapping), do: "invalid_wrapping"
  defp classify_reason(:malformed_wrapped_blob), do: "malformed_wrapped_blob"
  defp classify_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp classify_reason(%Ecto.Changeset{}), do: "changeset_invalid"

  defp classify_reason(reason) when is_exception(reason),
    do: reason.__struct__ |> Module.split() |> List.last()

  defp classify_reason(_other), do: "other"
end
