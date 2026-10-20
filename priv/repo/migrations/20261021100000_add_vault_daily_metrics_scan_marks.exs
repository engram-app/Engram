defmodule Engram.Repo.Migrations.AddVaultDailyMetricsScanMarks do
  use Ecto.Migration

  @moduledoc """
  `vault_daily_metrics.change_seq` and `.scanned_on`: what lets the daily
  snapshot (`Engram.Insights.Snapshot`) copy an unchanged vault's sizes from
  the day before instead of reading every one of its notes again.
  `change_seq` is the vault's seq when the sizes were read; `scanned_on` is the
  day they were last really read (a copy keeps it, so a week later the vault
  is read again).

  Nullable, no default, no backfill: a row without them is never copied, so
  existing rows just get read once more. A metadata-only ALTER; additive.
  """

  def change do
    alter table(:vault_daily_metrics) do
      add :change_seq, :bigint
      add :scanned_on, :date
    end
  end
end
