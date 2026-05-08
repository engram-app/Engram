defmodule Engram.Repo.Migrations.T34AddPerRowDekVersion do
  use Ecto.Migration

  @moduledoc """
  T3.4 / H5 — adds a `dek_version :: integer` column to every table whose
  rows carry user-DEK ciphertext. Default 1 for legacy rows; future per-user
  or per-row rotation campaigns (T3.5 / T3.7) stamp the new version on every
  rewritten row.

  Read paths can decide which DEK to use for decrypt by inspecting this
  column once rotation introduces a `users.dek_version > 1` cohort. Today
  the column is informational — wrapping is single-version — but adding it
  now means future rotations don't require a schema migration mid-rollout.
  """

  def change do
    alter table(:notes) do
      add :dek_version, :integer, null: false, default: 1
    end

    alter table(:attachments) do
      add :dek_version, :integer, null: false, default: 1
    end

    alter table(:vaults) do
      add :dek_version, :integer, null: false, default: 1
    end
  end
end
