defmodule Engram.Repo.Migrations.DbHygieneTest do
  @moduledoc """
  #863 DB hygiene: the three redundant duplicate indexes are gone (each was
  a strict leading-column prefix of a wider index, pure write amplification
  on the hottest tables), and subscriptions.tier/status carry validated
  CHECK constraints (webhook-driven writes previously relied on app-side
  validate_inclusion only).
  """
  use Engram.DataCase, async: true

  test "duplicate indexes are dropped" do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT indexname FROM pg_indexes
        WHERE indexname IN ('idx_chunks_note', 'notes_vault_id_index', 'attachments_vault_id_index')
        """,
        []
      )

    assert rows == [], "redundant duplicate indexes still present: #{inspect(rows)}"
  end

  for conname <- ["subscriptions_tier_check", "subscriptions_status_check"] do
    test "#{conname} exists and is validated" do
      %{rows: rows} =
        Repo.query!(
          "SELECT convalidated FROM pg_constraint WHERE conname = $1",
          [unquote(conname)]
        )

      assert [[true]] = rows, "missing/unvalidated constraint #{unquote(conname)}"
    end
  end
end
