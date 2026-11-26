defmodule Engram.Release.FolderHashDropTest do
  @moduledoc """
  Release K's owner-run boot step (`Engram.Release.FolderHashDrop`), run by
  `Engram.Release.migrate/0` after the migrations: it drops
  `folders_full_path`, then `folders.full_path_hmac`, and can never fail or
  block boot. A lock it cannot get in 5 s is a warning, the ledger stays
  open and the next boot retries. Its kill switch is the flag
  `folder_path_hash_drop`, read from the flags source once at boot;
  default (no source, an unreachable one, a timeout): run.

  Each test puts the column and the index back, committed (the step runs
  outside the sandbox: CONCURRENTLY cannot run in a transaction), and drops
  them again on exit, so the shared test DB ends as release K leaves it.
  """
  use Engram.DataCase, async: false

  import Engram.ServiceFlagsHelpers, only: [use_source: 1]
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Release.FolderHashDrop
  alias Engram.Repo

  @index_spec "ON folders (vault_id, full_path_hmac) " <>
                "WHERE full_path_hmac IS NOT NULL AND deleted_at IS NULL"

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)

  defp drop_all! do
    unboxed(fn ->
      Repo.query!("DROP INDEX IF EXISTS folders_full_path")
      Repo.query!("ALTER TABLE folders DROP COLUMN IF EXISTS full_path_hmac")
      Repo.query!("DELETE FROM data_migrations WHERE name = $1", [FolderHashDrop.name()])
    end)

    Engram.DataMigrations.reset_cache()
  end

  setup do
    drop_all!()

    unboxed(fn ->
      Repo.query!("ALTER TABLE folders ADD COLUMN full_path_hmac bytea")
      Repo.query!("CREATE INDEX folders_full_path #{@index_spec}")
    end)

    on_exit(&drop_all!/0)
    :ok
  end

  # {column present, index present}
  defp present do
    unboxed(fn ->
      %{rows: [[c, i]]} =
        Repo.query!("""
        SELECT
          (SELECT count(*)::int FROM pg_attribute
           WHERE attrelid = 'public.folders'::regclass AND attname = 'full_path_hmac'
             AND NOT attisdropped),
          (SELECT count(*)::int FROM pg_class WHERE relname = 'folders_full_path')
        """)

      {c, i}
    end)
  end

  # nil (no row), false (open) or true (done)
  defp ledger do
    unboxed(fn ->
      case Repo.query!("SELECT completed_at IS NOT NULL FROM data_migrations WHERE name = $1", [
             FolderHashDrop.name()
           ]).rows do
        [] -> nil
        [[done]] -> done
      end
    end)
  end

  defp run(opts \\ []), do: unboxed(fn -> FolderHashDrop.run(Repo, opts) end)

  defp flags_file!(doc) do
    path = Path.join(System.tmp_dir!(), "hash_drop_flags_#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(doc))
    on_exit(fn -> File.rm(path) end)
    use_source({:file, path})
  end

  # Another session holding ACCESS EXCLUSIVE on `folders` (a long migration,
  # a stuck transaction): both drops need a lock it blocks.
  defp hold_folders_lock! do
    {:ok, conn} =
      Repo.config()
      |> Keyword.drop([:pool, :pool_size, :parameters])
      |> Postgrex.start_link()

    Postgrex.query!(conn, "BEGIN", [])
    Postgrex.query!(conn, "LOCK TABLE folders IN ACCESS EXCLUSIVE MODE", [])
    conn
  end

  defp release!(conn) do
    Postgrex.query!(conn, "ROLLBACK", [])
    GenServer.stop(conn)
  end

  test "a held lock defers the drop; released, the next run drops both and completes" do
    conn = hold_folders_lock!()

    log = capture_log(fn -> assert run() == :deferred end)

    assert log =~ "folder_path_hash_drop deferred"
    assert present() == {1, 1}
    assert ledger() == false

    release!(conn)

    assert run() == :done
    assert present() == {0, 0}
    assert ledger() == true
  end

  test "a done ledger: later runs skip without touching the table" do
    assert run() == :done
    unboxed(fn -> Repo.query!("ALTER TABLE folders ADD COLUMN full_path_hmac bytea") end)

    assert run() == :skipped
    assert present() == {1, 0}
  end

  test "flags source says off: nothing runs" do
    flags_file!(%{"folder_path_hash_drop" => false})

    assert run() == :disabled
    assert present() == {1, 1}
    assert ledger() == nil
  end

  test "flags source says on: the step runs" do
    flags_file!(%{"folder_path_hash_drop" => true})

    assert run() == :done
    assert present() == {0, 0}
  end

  test "flags fetch times out: the step runs with the default and returns" do
    Req.Test.set_req_test_to_shared()

    Application.put_env(:engram, :service_flags_req_options,
      plug: {Req.Test, Engram.ServiceConfig.Flags},
      aws_sigv4: [access_key_id: "test", secret_access_key: "test", service: :appconfig]
    )

    on_exit(fn ->
      Application.delete_env(:engram, :service_flags_req_options)
      Req.Test.set_req_test_to_private()
    end)

    Req.Test.stub(Engram.ServiceConfig.Flags, fn conn ->
      Process.sleep(1_000)
      Req.Test.json(conn, %{"InitialConfigurationToken" => "t0"})
    end)

    use_source(
      {:appconfig, %{application: "app", environment: "env", profile: "prof", region: "us-east-1"}}
    )

    log = capture_log(fn -> assert run(flags_timeout_ms: 100) == :done end)

    assert log =~ "folder_path_hash_drop flags unreadable"
    assert present() == {0, 0}
  end
end
