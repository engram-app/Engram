defmodule Engram.DataMigrations.LinkResolutionKeys do
  @moduledoc """
  Every link candidate (note or attachment with a basename key) and every
  link edge carries its resolution keys (`path_ci_hmac` + `path_length`,
  `target_key_hmac`). Each pass enqueues `BackfillLinkKeys` per user who
  still has an unkeyed row. Reads are exact without the keys, only slower,
  so this saves work and gates nothing.

  Re-verifies daily: an older node during a rolling deploy, or a rollback,
  writes unkeyed rows again.
  """
  @behaviour Engram.DataMigration

  alias Engram.Workers.BackfillLinkKeys

  @impl true
  def name, do: "link_resolution_keys"

  @impl true
  def version, do: 1

  @impl true
  def reverify?, do: true

  @impl true
  def run_pass do
    case BackfillLinkKeys.enqueue_missing() do
      0 -> :done
      users -> {:more, users: users}
    end
  end
end
