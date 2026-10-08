defmodule Engram.DataMigrations.EnvelopeFormat do
  @moduledoc """
  Every compressible DB envelope on the current format (#1872 PR 3). Each pass
  enqueues `ReencodeEnvelopes` for every user who still has a legacy row
  (format 0: 12-byte nonce, more than the 16-byte tag) and no job running.
  Per user, not global: one user's job pinned behind a rotation lock must not
  stall everyone else. Done when none is left. Bump `version/0` when a new
  format ships.

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
    # Per-user in-flight handling lives in `enqueue_missing/0` (unique for
    # pending jobs, an explicit skip for :executing ones).
    case ReencodeEnvelopes.enqueue_missing() do
      0 -> :done
      users -> {:more, users: users}
    end
  end
end
