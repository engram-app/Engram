defmodule Engram.Repo.Migrations.AddClientLogsForcedExpand do
  use Ecto.Migration

  # `forced` records that a client entry bypassed the plugin's diagnostics gate
  # (RemoteLogger.anomaly/3 ships with force: true so a fresh install with
  # telemetry OFF still reports a silent first-sync failure).
  #
  # Nullable with a default, so this is forward-compatible with running code
  # that neither writes nor reads it — phase/expand.
  def change do
    alter table(:client_logs) do
      add :forced, :boolean, default: false, null: false
    end
  end
end
