defmodule Engram.DataMigrations.EnvelopeFormat do
  @moduledoc """
  Every compressible DB envelope on the current format (#1872 PR 3). Each pass
  enqueues `ReencodeEnvelopes` for every user who still has a legacy row
  (format 0: 12-byte nonce, more than the 16-byte tag), unless a job is still
  running. Done when none is left. Bump `version/0` when a new format ships.

  A legacy row that never decrypts keeps this open (one user's job per hour);
  the stuck-migration alert surfaces it. While the compression kill switch is
  set (`ENVELOPE_COMPRESSION=false`) a re-encode would write format 0 again,
  so the pass enqueues nothing and stays open.
  """
  @behaviour Engram.DataMigration

  alias Engram.DataMigrations
  alias Engram.Workers.ReencodeEnvelopes

  @impl true
  def name, do: "envelope_format"

  @impl true
  def version, do: 1

  @impl true
  def run_pass do
    # The worker has no `unique`: enqueueing while jobs run would duplicate them.
    cond do
      not Application.get_env(:engram, :envelope_compression, false) -> :more
      DataMigrations.jobs_in_flight?(ReencodeEnvelopes) -> :more
      ReencodeEnvelopes.enqueue_missing() == 0 -> :done
      true -> :more
    end
  end
end
