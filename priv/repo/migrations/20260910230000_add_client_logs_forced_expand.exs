defmodule Engram.Repo.Migrations.AddClientLogsForcedExpand do
  use Ecto.Migration

  # `forced` records that a client entry bypassed the plugin's diagnostics gate
  # (RemoteLogger.anomaly/3 ships with force: true so a fresh install with
  # telemetry OFF still reports a silent first-sync failure).
  #
  # NOT NULL with a constant DEFAULT — forward-compatible with running code
  # that neither writes nor reads it, because the DEFAULT (not nullability) is
  # what makes the old INSERT shape still valid. `%{forced: nil}` is NOT a legal
  # insert. phase/expand.
  def change do
    alter table(:client_logs) do
      add :forced, :boolean, default: false, null: false
    end
  end
end
