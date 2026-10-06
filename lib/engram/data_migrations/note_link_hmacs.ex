defmodule Engram.DataMigrations.NoteLinkHmacs do
  @moduledoc """
  Rows predating link extraction (#591) have a NULL `basename_hmac` and no
  `note_links` edges. Each pass enqueues the `BackfillNoteLinks` chain, unless
  one is still running. Done when no note or attachment in any tenant lacks a
  `basename_hmac`, using the worker's own `note_hmacs` / `attachment_hmacs`
  predicates (deleted rows included, as the worker processes them).
  """
  @behaviour Engram.DataMigration

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.DataMigrations
  alias Engram.Links.Backfill
  alias Engram.Notes.Note
  alias Engram.Workers.BackfillNoteLinks

  @impl true
  def name, do: "note_link_hmacs"

  @impl true
  def version, do: 1

  @impl true
  def run_pass do
    cond do
      DataMigrations.jobs_in_flight?(BackfillNoteLinks) ->
        :more

      missing_hmacs?() ->
        Backfill.enqueue_all()
        :more

      true ->
        :done
    end
  end

  defp missing_hmacs? do
    DataMigrations.any_row?(fn _repo ->
      from(n in Note,
        where: n.kind == "note" and is_nil(n.basename_hmac) and not is_nil(n.path_ciphertext),
        select: 1
      )
    end) or
      DataMigrations.any_row?(fn _repo ->
        from(a in Attachment,
          where: is_nil(a.basename_hmac) and not is_nil(a.path_ciphertext),
          select: 1
        )
      end)
  end
end
