defmodule Engram.Repo.Migrations.AddRebuildPaidAtToNotesExpand do
  @moduledoc """
  phase/expand. `notes.rebuild_paid_at`: set when a v5 rebuild pass of the
  note got its vectors back from Voyage, cleared when any pass commits the
  note's index (chunker v5 Task 16.3). A rebuild pass that would call Voyage
  again while it is set parks the note `rebuild_double_pay` instead.

  Nullable add only: metadata-only on PG11+, no rewrite, no default.
  :timestamptz for Squawk (prefer-timestamp-tz); the field is :utc_datetime_usec.
  """
  use Ecto.Migration

  def change do
    alter table(:notes) do
      add :rebuild_paid_at, :timestamptz
    end
  end
end
