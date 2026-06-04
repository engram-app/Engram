defmodule Mix.Tasks.Engram.MigrationDropsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Engram.MigrationDrops

  defp write_migration(tmp_dir, name, body) do
    path = Path.join(tmp_dir, name)
    File.write!(path, body)
    path
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "mig_drops_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  test "extracts column drops via remove/1 and remove/2", %{tmp: tmp} do
    path =
      write_migration(tmp, "001.exs", """
      defmodule M do
        use Ecto.Migration
        def change do
          alter table(:users) do
            remove(:legacy_flag)
            remove(:old_name, :string)
          end
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{
             columns: [{"users", "legacy_flag"}, {"users", "old_name"}],
             tables: []
           }
  end

  test "extracts column drops via remove_if_exists", %{tmp: tmp} do
    path =
      write_migration(tmp, "002.exs", """
      defmodule M do
        use Ecto.Migration
        def change do
          alter table(:notes) do
            remove_if_exists(:deprecated_field, :text)
          end
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{
             columns: [{"notes", "deprecated_field"}],
             tables: []
           }
  end

  test "extracts table drops via drop and drop_if_exists", %{tmp: tmp} do
    path =
      write_migration(tmp, "003.exs", """
      defmodule M do
        use Ecto.Migration
        def change do
          drop(table(:legacy_audit))
          drop_if_exists(table(:old_index_cache))
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{
             columns: [],
             tables: ["legacy_audit", "old_index_cache"]
           }
  end

  test "ignores drops nested inside `# safety_assured:` magic-comment lines", %{tmp: tmp} do
    # The comment-based escape will be enforced in Tier 3 via a dedicated
    # Credo check. For Tier 1 we only require that a file-level magic comment
    # at the top of the migration short-circuits extraction entirely, so the
    # contract gate doesn't double-flag intentionally-bypassed drops.
    path =
      write_migration(tmp, "004.exs", """
      # safety_assured: "legacy_audit table is replaced by audit_v2; backfill done in 0.5.123"
      defmodule M do
        use Ecto.Migration
        def change do
          drop(table(:legacy_audit))
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [], tables: []}
  end

  test "returns empty maps for migrations with no drops", %{tmp: tmp} do
    path =
      write_migration(tmp, "005.exs", """
      defmodule M do
        use Ecto.Migration
        def change do
          alter table(:users) do
            add(:timezone, :string)
          end
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [], tables: []}
  end
end
