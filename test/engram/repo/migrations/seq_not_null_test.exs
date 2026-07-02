defmodule Engram.Repo.Migrations.SeqNotNullTest do
  @moduledoc """
  The seq change feed silently EXCLUDES rows with NULL seq (`list_changes_seq`
  filters `not is_nil(n.seq)`), so a forgotten `put_change(:seq, ...)` in a
  future write path would mean notes that never sync, with no error anywhere.
  The DB must enforce the invariant: validated NOT NULL constraints on
  notes.seq and attachments.seq (PG18 named-constraint pattern, see AGENTS.md
  "PG18-era cheap patterns").
  """
  use Engram.DataCase, async: true

  for {table, conname} <- [
        {"notes", "notes_seq_not_null"},
        {"attachments", "attachments_seq_not_null"}
      ] do
    test "#{table}.seq carries a validated NOT NULL constraint" do
      %{rows: rows} =
        Repo.query!(
          """
          SELECT convalidated FROM pg_constraint
          WHERE conrelid = to_regclass($1) AND conname = $2
          """,
          [unquote(table), unquote(conname)]
        )

      assert [[true]] = rows,
             "#{unquote(table)}.seq must have validated NOT NULL constraint " <>
               "#{unquote(conname)} — NULL-seq rows silently vanish from the sync feed"
    end
  end
end
