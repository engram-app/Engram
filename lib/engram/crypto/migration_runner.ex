defmodule Engram.Crypto.MigrationRunner do
  @moduledoc """
  Shared scaffolding for the per-user crypto migration drivers
  (`MasterRotation`, `ProviderMigration`, `AadRebind`, `UserDekRotation`).

  Only the trivially identical pieces live here: the cursor-driven fleet
  loop and the monotonic duration helper. Telemetry emission and reason
  classification deliberately stay in each migration module — their event
  names, metadata shapes, and reason-label sets differ per migration and
  are contractual (dashboards/alerts key on them), so a shared emitter
  would either change wire shapes or need one parameter per divergence.
  """

  # UUIDv7 ids sort above the all-zero UUID, so this is the cursor floor.
  @zero_uuid "00000000-0000-0000-0000-000000000000"

  @typedoc "Aggregate tally from streaming a migration over the user fleet."
  @type counts :: %{ok: non_neg_integer(), skipped: non_neg_integer(), failed: non_neg_integer()}

  @doc """
  Cursor-driven fleet loop shared by the `*_all` drivers.

  `fetch_ids.(last_id)` returns the next batch of user ids strictly above
  `last_id` in ascending order (the caller's query closes over its own
  filter + batch size); an empty batch terminates the loop. `per_id.(id)`
  runs one per-user migration — each in its own transaction, exactly as
  before — and its `:ok | :skipped | {:error, _}` result is tallied.

  `initial` seeds the tally: `ProviderMigration.migrate_all/2` pre-counts
  already-at-target users as `:skipped` without visiting them.
  """
  @spec drive(
          (String.t() -> [String.t()]),
          (String.t() -> :ok | :skipped | {:error, term()}),
          counts()
        ) :: counts()
  def drive(fetch_ids, per_id, initial \\ %{ok: 0, skipped: 0, failed: 0}) do
    drive_loop(fetch_ids, per_id, @zero_uuid, initial)
  end

  defp drive_loop(fetch_ids, per_id, last_id, acc) do
    case fetch_ids.(last_id) do
      [] ->
        acc

      ids ->
        acc =
          Enum.reduce(ids, acc, fn id, a ->
            case per_id.(id) do
              :ok -> Map.update!(a, :ok, &(&1 + 1))
              :skipped -> Map.update!(a, :skipped, &(&1 + 1))
              {:error, _} -> Map.update!(a, :failed, &(&1 + 1))
            end
          end)

        drive_loop(fetch_ids, per_id, List.last(ids), acc)
    end
  end

  @doc "Microseconds elapsed since a `System.monotonic_time/0` capture."
  @spec duration_us_since(integer()) :: integer()
  def duration_us_since(started_at) do
    System.convert_time_unit(
      System.monotonic_time() - started_at,
      :native,
      :microsecond
    )
  end
end
