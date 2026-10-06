defmodule Engram.DataMigrations.NoteLinkHmacs do
  @moduledoc """
  Rows predating link extraction (#591) have a NULL `basename_hmac` and no
  `note_links` edges. Each pass enqueues the `BackfillNoteLinks` chain for
  every (user, vault) with such a row (`Links.Backfill.enqueue_missing/0`),
  unless a chain is still running. Done when that finds no pair: the filter
  the worker's `note_hmacs` / `attachment_hmacs` scopes use, in a live vault
  (the worker discards a deleted vault's jobs). Deleted rows count, as the
  worker stamps them. A row whose path never decrypts keeps it open, at the
  cost of one vault's chain per hour.

  Done tracks the hmacs only: a final `links`-scope job discarded after its
  retries can close this with that vault's edges unbuilt.
  """
  @behaviour Engram.DataMigration

  alias Engram.DataMigrations
  alias Engram.Links.Backfill
  alias Engram.Workers.BackfillNoteLinks

  @impl true
  def name, do: "note_link_hmacs"

  @impl true
  def version, do: 1

  @impl true
  def run_pass do
    # The worker has no `unique`: enqueueing while a chain runs would
    # duplicate it.
    cond do
      DataMigrations.jobs_in_flight?(BackfillNoteLinks) -> :more
      Backfill.enqueue_missing() == 0 -> :done
      true -> :more
    end
  end
end
