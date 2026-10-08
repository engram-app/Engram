defmodule Engram.DataMigrations.EnvelopeFormat do
  @moduledoc """
  Every compressible DB envelope on the current format (#1872 PR 3). Each pass
  enqueues `ReencodeEnvelopes` for every user who still has a legacy row
  (format 0: 12-byte nonce, more than the 16-byte tag), unless a job is still
  running. Done when none is left. Bump `version/0` when a new format ships.

  A legacy row that never decrypts keeps this open (one user's job per hour);
  the stuck-migration alert surfaces it.

  Disabled (`enabled?/0`) while compression is off (`Envelope.compression_on?/0`:
  the `ENVELOPE_COMPRESSION=false` kill switch, or a cluster node that cannot
  read format 1): a re-encode would write format 0 again. Disabled pauses
  without paging (the runner holds the stuck clock). Rows
  written in that window (or by an older node after a rollback) are legacy
  again after `:done`, so this opts into the runner's daily re-verify, which
  reopens it when one appears.
  """
  @behaviour Engram.DataMigration

  alias Engram.DataMigrations
  alias Engram.Workers.ReencodeEnvelopes

  @impl true
  def name, do: "envelope_format"

  @impl true
  def version, do: 1

  @impl true
  def enabled?, do: Engram.Crypto.Envelope.compression_on?()

  @impl true
  def reverify?, do: true

  @impl true
  def run_pass do
    # The worker is unique per user over available/scheduled/retryable, but unique
    # does not cover :executing; the jobs_in_flight? guard also stops new chains
    # while a chain's last hop runs.
    cond do
      DataMigrations.jobs_in_flight?(ReencodeEnvelopes) -> :more
      ReencodeEnvelopes.enqueue_missing() == 0 -> :done
      true -> :more
    end
  end
end
