defmodule Mix.Tasks.Engram.PreflightTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Engram.Preflight

  defmodule FakeRepo do
    def __adapter__, do: Ecto.Adapters.Postgres
    def config, do: [migration_source: "schema_migrations"]
  end

  defp tmp_migrations(files) do
    dir = Path.join(System.tmp_dir!(), "preflight_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(files, fn {name, body} -> File.write!(Path.join(dir, name), body) end)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "report/2 lists pending migrations with their phase tag and irreversibility flag" do
    dir =
      tmp_migrations([
        {"20260101000000_add_col.exs",
         """
         # phase: expand
         defmodule M do
           use Ecto.Migration
           def change, do: alter table(:users) do add(:tz, :string) end
         end
         """},
        {"20260202000000_drop_col.exs",
         """
         # phase: contract
         # rollback-irreversible
         defmodule M do
           use Ecto.Migration
           def up, do: alter table(:users) do remove(:legacy) end
           def down, do: raise "irreversible"
         end
         """}
      ])

    result = Preflight.report(FakeRepo, migrations_dir: dir, applied_versions: [])

    assert length(result.pending) == 2
    assert Enum.at(result.pending, 0).phase == :expand
    assert Enum.at(result.pending, 0).irreversible == false
    assert Enum.at(result.pending, 1).phase == :contract
    assert Enum.at(result.pending, 1).irreversible == true
  end

  test "report/2 omits rollback_command when any pending is irreversible" do
    dir =
      tmp_migrations([
        {"20260101000000_irrev.exs",
         """
         # rollback-irreversible
         defmodule M do
           use Ecto.Migration
           def up, do: :ok
           def down, do: raise "no"
         end
         """}
      ])

    result = Preflight.report(FakeRepo, migrations_dir: dir, applied_versions: [])
    assert is_nil(result.rollback_command)
  end

  test "report/2 emits a rollback_command pointing at the previous applied version when reversible" do
    dir =
      tmp_migrations([
        {"20260202000000_new.exs",
         """
         defmodule M do
           use Ecto.Migration
           def change, do: alter table(:users) do add(:tz, :string) end
         end
         """}
      ])

    result =
      Preflight.report(FakeRepo,
        migrations_dir: dir,
        applied_versions: [20_260_101_000_000]
      )

    assert result.rollback_command ==
             "bin/engram eval 'Engram.Release.rollback(Engram.Repo, 20260101000000)'"
  end

  test "report/2 flags lock_risk: :high for CREATE INDEX without CONCURRENTLY" do
    dir =
      tmp_migrations([
        {"20260101000000_index.exs",
         """
         defmodule M do
           use Ecto.Migration
           def change, do: create index(:users, [:email])
         end
         """}
      ])

    result = Preflight.report(FakeRepo, migrations_dir: dir, applied_versions: [])
    assert Enum.at(result.pending, 0).lock_risk == :high
  end

  test "report/2 flags lock_risk: :low for CONCURRENTLY indexes" do
    dir =
      tmp_migrations([
        {"20260101000000_index.exs",
         """
         defmodule M do
           use Ecto.Migration
           @disable_ddl_transaction true
           def change, do: create index(:users, [:email], concurrently: true)
         end
         """}
      ])

    result = Preflight.report(FakeRepo, migrations_dir: dir, applied_versions: [])
    assert Enum.at(result.pending, 0).lock_risk == :low
  end

  test "report/2 returns empty pending list when fully up to date" do
    dir =
      tmp_migrations([
        {"20260101000000_a.exs", "defmodule M do use Ecto.Migration; def change, do: :ok end"}
      ])

    result =
      Preflight.report(FakeRepo,
        migrations_dir: dir,
        applied_versions: [20_260_101_000_000]
      )

    assert result.pending == []
    assert is_nil(result.rollback_command)
  end

  test "report/2 flags lock_risk: :high for drop table" do
    dir =
      tmp_migrations([
        {"20260101000000_drop_tbl.exs",
         """
         defmodule M do
           use Ecto.Migration
           def change, do: drop(table(:legacy_audit))
         end
         """}
      ])

    result = Preflight.report(FakeRepo, migrations_dir: dir, applied_versions: [])
    assert Enum.at(result.pending, 0).lock_risk == :high
  end

  test "report/2 flags lock_risk: :high for rename table" do
    dir =
      tmp_migrations([
        {"20260101000000_rename.exs",
         """
         defmodule M do
           use Ecto.Migration
           def change, do: rename table(:users), to: table(:accounts)
         end
         """}
      ])

    result = Preflight.report(FakeRepo, migrations_dir: dir, applied_versions: [])
    assert Enum.at(result.pending, 0).lock_risk == :high
  end

  test "report/2 flags lock_risk: :high for modify with options" do
    dir =
      tmp_migrations([
        {"20260101000000_modify.exs",
         """
         defmodule M do
           use Ecto.Migration
           def change do
             alter table(:users) do
               modify(:email, :text, null: false)
             end
           end
         end
         """}
      ])

    result = Preflight.report(FakeRepo, migrations_dir: dir, applied_versions: [])
    assert Enum.at(result.pending, 0).lock_risk == :high
  end
end
