defmodule Engram.DataMigrations.ContentHashHmac do
  @moduledoc """
  Legacy MD5 `content_hash` values become HMAC-SHA256 (Phase A). Each pass
  enqueues the `BackfillContentHashHmac` chain for every (user, vault) with a
  legacy hash, unless a chain is still running. Done when `enqueue_all/0`
  finds no pair holding a 32-char hash, which is the same scan and filter the
  worker uses, so a row it can never fix keeps the migration open.
  """
  @behaviour Engram.DataMigration

  alias Engram.ContentHash.Backfill
  alias Engram.DataMigrations
  alias Engram.Workers.BackfillContentHashHmac

  @impl true
  def name, do: "content_hash_hmac"

  @impl true
  def version, do: 1

  @impl true
  def run_pass do
    # The worker has no `unique` (#1230): enqueueing while a chain runs
    # would duplicate it.
    if DataMigrations.jobs_in_flight?(BackfillContentHashHmac) do
      :more
    else
      case Backfill.enqueue_all() do
        %{notes: 0, attachments: 0} -> :done
        _ -> :more
      end
    end
  end
end
