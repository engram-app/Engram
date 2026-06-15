defmodule Mix.Tasks.Engram.IndexAuditTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Engram.IndexAudit

  defp idx(attrs) do
    Map.merge(
      %{
        name: "ix",
        table: "notes",
        columns: ["a"],
        scans: 5,
        unique: false,
        primary: false,
        valid: true,
        leading_n_distinct: 1000,
        size_bytes: 8192
      },
      Map.new(attrs)
    )
  end

  describe "never_scanned" do
    test "flags a non-unique, non-primary index with zero scans" do
      result = IndexAudit.analyze([idx(name: "idx_dead", scans: 0)])

      assert [%{index: "idx_dead", table: "notes"}] = result.never_scanned
    end

    test "does not flag an index that has been scanned" do
      result = IndexAudit.analyze([idx(name: "idx_live", scans: 42)])

      assert result.never_scanned == []
    end

    test "never flags a unique index even with zero scans (enforces a constraint)" do
      result = IndexAudit.analyze([idx(name: "uniq", scans: 0, unique: true)])

      assert result.never_scanned == []
    end

    test "never flags a primary key index even with zero scans" do
      result = IndexAudit.analyze([idx(name: "pk", scans: 0, primary: true)])

      assert result.never_scanned == []
    end

    test "ignores invalid indexes (in-progress / failed CREATE CONCURRENTLY)" do
      result = IndexAudit.analyze([idx(name: "broken", scans: 0, valid: false)])

      assert result.never_scanned == []
    end
  end

  describe "skip_scan_redundant" do
    test "flags a single-column index covered by a composite with a low-cardinality leading column" do
      composite =
        idx(name: "notes_user_level", columns: ["user_id", "level"], leading_n_distinct: 8)

      single = idx(name: "notes_level", columns: ["level"])

      result = IndexAudit.analyze([composite, single])

      assert [%{index: "notes_level", covered_by: "notes_user_level"}] =
               result.skip_scan_redundant
    end

    test "does not flag when the composite's leading column is high cardinality" do
      composite =
        idx(name: "notes_user_level", columns: ["user_id", "level"], leading_n_distinct: 500_000)

      single = idx(name: "notes_level", columns: ["level"])

      result = IndexAudit.analyze([composite, single])

      assert result.skip_scan_redundant == []
    end

    test "does not flag when the covered column is not the immediate second column (conservative)" do
      composite =
        idx(name: "notes_a_b_level", columns: ["a", "b", "level"], leading_n_distinct: 3)

      single = idx(name: "notes_level", columns: ["level"])

      result = IndexAudit.analyze([composite, single])

      assert result.skip_scan_redundant == []
    end

    test "never flags a unique single-column index (it enforces a constraint)" do
      composite =
        idx(name: "notes_user_email", columns: ["user_id", "email"], leading_n_distinct: 4)

      single = idx(name: "notes_email_uniq", columns: ["email"], unique: true)

      result = IndexAudit.analyze([composite, single])

      assert result.skip_scan_redundant == []
    end

    test "does not match a composite on a different table" do
      composite =
        idx(
          name: "other_user_level",
          table: "chunks",
          columns: ["user_id", "level"],
          leading_n_distinct: 5
        )

      single = idx(name: "notes_level", table: "notes", columns: ["level"])

      result = IndexAudit.analyze([composite, single])

      assert result.skip_scan_redundant == []
    end

    test "threshold is configurable via :low_cardinality_threshold" do
      composite =
        idx(name: "notes_user_level", columns: ["user_id", "level"], leading_n_distinct: 50)

      single = idx(name: "notes_level", columns: ["level"])

      assert IndexAudit.analyze([composite, single], low_cardinality_threshold: 10).skip_scan_redundant ==
               []

      assert [%{index: "notes_level"}] =
               IndexAudit.analyze([composite, single], low_cardinality_threshold: 100).skip_scan_redundant
    end
  end
end
