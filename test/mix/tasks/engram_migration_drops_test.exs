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

  test "ignores drops that only appear in down/0 (an additive migration's reversal)", %{tmp: tmp} do
    path =
      write_migration(tmp, "010.exs", """
      defmodule M do
        use Ecto.Migration
        def up do
          alter table(:notes) do
            add :label, :text
          end
          create table(:things)
        end
        def down do
          alter table(:notes) do
            remove :label
          end
          drop table(:things)
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [], tables: []}
  end

  test "still extracts a remove inside change/0 (an up-direction drop)", %{tmp: tmp} do
    path =
      write_migration(tmp, "011.exs", """
      defmodule M do
        use Ecto.Migration
        def change do
          alter table(:notes) do
            remove :legacy, :string
          end
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [{"notes", "legacy"}], tables: []}
  end

  test "treats a column rename as dropping the old name", %{tmp: tmp} do
    path =
      write_migration(tmp, "012.exs", """
      defmodule M do
        use Ecto.Migration
        def change do
          rename table(:notes), :title, to: :name
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [{"notes", "title"}], tables: []}
  end

  test "treats a table rename as dropping the old table name", %{tmp: tmp} do
    path =
      write_migration(tmp, "013.exs", """
      defmodule M do
        use Ecto.Migration
        def change do
          rename table(:old_things), to: table(:things)
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [], tables: ["old_things"]}
  end

  test "raw SQL DROP in execute/1 is reported as unparseable", %{tmp: tmp} do
    path =
      write_migration(tmp, "014.exs", """
      defmodule M do
        use Ecto.Migration
        def up do
          execute("ALTER TABLE notes DROP COLUMN legacy, DROP COLUMN other")
        end
        def down, do: :ok
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [], tables: [], raw_sql: true}
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

  test "extracts drops when table name is a string literal", %{tmp: tmp} do
    path =
      write_migration(tmp, "006.exs", """
      defmodule M do
        use Ecto.Migration
        def change do
          alter table("users") do
            remove(:legacy_col)
          end
          drop(table("old_cache"))
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{
             columns: [{"users", "legacy_col"}],
             tables: ["old_cache"]
           }
  end

  test "raises a clear Mix error on syntax-broken migration", %{tmp: tmp} do
    path =
      write_migration(tmp, "007.exs", """
      defmodule M do
        use Ecto.Migration
        def change do
          alter table(:users)  # missing `do` block
      """)

    assert_raise Mix.Error, ~r/#{Regex.escape(path)}: syntax error at line/, fn ->
      MigrationDrops.extract(path)
    end
  end

  test "safety_assured: with empty content does NOT bypass extraction", %{tmp: tmp} do
    path =
      write_migration(tmp, "100.exs", """
      # safety_assured: ""
      defmodule M do
        use Ecto.Migration
        def change do
          drop(table(:legacy_audit))
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [], tables: ["legacy_audit"]}
  end

  test "safety_assured: with unclosed quote does NOT bypass extraction", %{tmp: tmp} do
    path =
      write_migration(tmp, "101.exs", """
      # safety_assured: "
      defmodule M do
        use Ecto.Migration
        def change do
          drop(table(:legacy_audit))
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [], tables: ["legacy_audit"]}
  end

  test "safety_assured: works when the comment is past the first 20 lines", %{tmp: tmp} do
    long_header = String.duplicate("# preamble line\n", 25)

    path =
      write_migration(tmp, "102.exs", """
      #{long_header}# safety_assured: "audited 2026-06-04 — column already unused in prod"
      defmodule M do
        use Ecto.Migration
        def change do
          drop(table(:legacy_audit))
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [], tables: []}
  end

  # Raw SQL a migration hands to a helper (LockTimeoutRetry) instead of
  # execute/1: the gate must still see the drop, or nothing checks it.
  test "parses a raw single-column drop passed to a helper", %{tmp: tmp} do
    path =
      write_migration(tmp, "020.exs", """
      defmodule M do
        use Ecto.Migration
        def up do
          LockTimeoutRetry.with_lock_timeout(repo(), [
            "DROP INDEX CONCURRENTLY IF EXISTS note_links_qualified",
            "ALTER TABLE note_links DROP COLUMN IF EXISTS qualified"
          ])
        end
        def down do
          LockTimeoutRetry.with_lock_timeout(repo(), [
            "ALTER TABLE note_links DROP COLUMN IF EXISTS other_col"
          ])
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [{"note_links", "qualified"}], tables: []}
  end

  test "parses raw single drops in execute/1", %{tmp: tmp} do
    path =
      write_migration(tmp, "021.exs", """
      defmodule M do
        use Ecto.Migration
        def up do
          execute("ALTER TABLE ONLY \\"notes\\" DROP COLUMN legacy CASCADE;")
          execute("DROP TABLE IF EXISTS legacy_audit")
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{
             columns: [{"notes", "legacy"}],
             tables: ["legacy_audit"]
           }
  end

  test "a drop named in @moduledoc prose is not a drop", %{tmp: tmp} do
    path =
      write_migration(tmp, "022.exs", """
      defmodule M do
        use Ecto.Migration
        @moduledoc "Later, ALTER TABLE notes DROP COLUMN legacy; DROP TABLE x."
        def up, do: :ok
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [], tables: []}
  end

  test "ignores drops in a down helper (`def down, do: run_down(repo())`)", %{tmp: tmp} do
    path =
      write_migration(tmp, "023.exs", """
      defmodule M do
        use Ecto.Migration
        def up, do: run_up(repo())
        def down, do: run_down(repo())
        def run_up(repo), do: repo.query!("ALTER TABLE notes ADD COLUMN x int")
        def run_down(repo) do
          LockTimeoutRetry.with_lock_timeout(repo, ["ALTER TABLE notes DROP COLUMN IF EXISTS x"])
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [], tables: []}
  end

  # A `_down` name is not a down helper: only what `down` reaches counts.
  test "a drop in a helper up calls is a drop, whatever its name", %{tmp: tmp} do
    path =
      write_migration(tmp, "024.exs", """
      defmodule M do
        use Ecto.Migration
        def up do
          shut_down()
          wind_down(repo())
        end
        def down, do: run_down(repo())
        defp shut_down, do: execute("DROP TABLE a")
        defp wind_down(r), do: r.query!("ALTER TABLE a DROP COLUMN b")
        def run_down(r), do: r.query!("ALTER TABLE a DROP COLUMN c")
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [{"a", "b"}], tables: ["a"]}
  end

  test "a helper both directions call still counts", %{tmp: tmp} do
    path =
      write_migration(tmp, "025.exs", """
      defmodule M do
        use Ecto.Migration
        def up, do: run_down(repo())
        def down, do: run_down(repo())
        def run_down(r), do: r.query!("ALTER TABLE a DROP COLUMN c")
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [{"a", "c"}], tables: []}
  end

  test "execute/2 in change counts only its up statement", %{tmp: tmp} do
    path =
      write_migration(tmp, "026.exs", """
      defmodule M do
        use Ecto.Migration
        def change do
          execute("ALTER TABLE a ADD COLUMN b int", "ALTER TABLE a DROP COLUMN b")
          execute("ALTER TABLE a DROP COLUMN c", "ALTER TABLE a ADD COLUMN c int")
        end
      end
      """)

    assert MigrationDrops.extract(path) == %{columns: [{"a", "c"}], tables: []}
  end
end
