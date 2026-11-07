defmodule Engram.Folders.DriftTest do
  # The drift predicates have one source (`Engram.Folders.Drift`), used by the
  # drain, FolderTable and the folder readers. The migrations that built the
  # partial indexes keep their own literal (a migration must not call app
  # code): if either side changes alone, the readers stop matching the index.
  use ExUnit.Case, async: true

  alias Engram.Bookkeeping.Drain
  alias Engram.Folders.Drift

  @migrations Path.expand("../../../priv/repo/migrations", __DIR__)

  # The migration's text as the SQL it sends: whitespace collapsed, the
  # source's escaped backslash as one.
  defp migration_sql(file) do
    @migrations
    |> Path.join(file)
    |> File.read!()
    |> String.replace("\\\\", "\\")
    |> String.replace(~r/\s+/, " ")
  end

  test "notes_unresolved_folder's migration carries the shared predicate" do
    assert migration_sql("20261103130200_index_drift_drain_expand.exs") =~
             Drift.notes_unresolved_sql()
  end

  test "attachments_folder_ref_stale's migration carries the shared predicate" do
    assert migration_sql("20261103140100_index_attachments_folder_ref_stale_expand.exs") =~
             Drift.attachments_stale_sql()
  end

  test "the drain's folder probes are built from it" do
    [{"notes", notes}, {"attachments", atts}] = Drain.probes(:folder)
    assert notes =~ Drift.notes_unresolved_sql()
    assert atts =~ Drift.attachments_stale_sql()
  end

  test "the unreadable stamp in the stale predicate is Rows.unreadable_attachment_stamp/1's" do
    assert Engram.Folders.Rows.unreadable_attachment_stamp("n") == <<0, ?n>>
    assert Drift.attachments_stale_sql() =~ "('\\x00'::bytea || path_nonce)"
  end
end
