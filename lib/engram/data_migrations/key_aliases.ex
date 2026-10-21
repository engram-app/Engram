defmodule Engram.DataMigrations.KeyAliases do
  @moduledoc """
  Every content-current note read under the current key alias table
  (`Engram.Notes.KeyAliases.version/0`, a content hash of the generated
  catalog). Each pass enqueues `HealKeyAliases` per user who still has a
  note stamped with another version. The name carries the version, so a
  regenerated table is a new, not-done migration.

  Off (skipped by the runner, never marked done) unless the v5 rebuild is
  `on` (`Engram.Rebuild.mode/0`), where the ledger meters what its
  re-indexes spend. Before that every row is unstamped and a heal re-chunks
  the note under the unstamped v5 chunker and pays Voyage; the v5 rebuild
  re-reads every note anyway (`EmbedNote` stamps the version on a full
  pass). The payload format flag alone can be flipped first, so it is not
  the gate. A later regenerated table heals in the next `on` window.
  """
  @behaviour Engram.DataMigration

  alias Engram.Notes.KeyAliases
  alias Engram.Workers.HealKeyAliases

  @impl true
  def name, do: "key_aliases:#{KeyAliases.version()}"

  @impl true
  def version, do: 1

  @impl true
  def enabled?, do: Engram.Rebuild.mode() == :on

  @impl true
  def run_pass do
    case HealKeyAliases.enqueue_missing() do
      0 -> :done
      users -> {:more, users: users}
    end
  end
end
