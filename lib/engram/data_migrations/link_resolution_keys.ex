defmodule Engram.DataMigrations.LinkResolutionKeys do
  @moduledoc """
  Every link candidate (note or attachment with a basename key) and every
  link edge carries current resolution keys (`path_ci_hmac` + `path_length`,
  `target_key_hmac`, stamped for its nonce and the Unicode version). Each
  pass enqueues `BackfillLinkKeys` per user who still has an unkeyed row. Reads are exact without the keys, only slower,
  so this saves work and gates nothing.

  Re-verifies daily: an older node during a rolling deploy, or a rollback,
  re-encrypts rows without restamping them.
  """
  @behaviour Engram.DataMigration

  alias Engram.Workers.BackfillLinkKeys

  @impl true
  # Unicode decides grapheme length and lowercasing, so a new Unicode version
  # (an Elixir upgrade) is a new, not-done migration, as `IndexVersions`
  # embeds its versions.
  def name, do: "link_resolution_keys_unicode_" <> Engram.Links.link_keys_version()

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
