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
    path =
      Path.join(System.tmp_dir!(), "hash_drop_flags_#{System.unique_integer([:positive])}.json")

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

  # AppConfig answered by a Req.Test stub; `sign` false keeps ex_aws's own
  # credential chain (the prod path) instead of fixed test credentials.
  defp appconfig!(sign \\ true) do
    Req.Test.set_req_test_to_shared()
    opts = [plug: {Req.Test, Engram.ServiceConfig.Flags}]

    opts =
      if sign,
        do:
          opts ++
            [aws_sigv4: [access_key_id: "test", secret_access_key: "test", service: :appconfig]],
        else: opts

    Application.put_env(:engram, :service_flags_req_options, opts)

    on_exit(fn ->
      Application.delete_env(:engram, :service_flags_req_options)
      Req.Test.set_req_test_to_private()
    end)

    use_source(
      {:appconfig,
       %{application: "app", environment: "env", profile: "prof", region: "us-east-1"}}
    )
  end

  defp serve_flags!(doc) do
    Req.Test.stub(Engram.ServiceConfig.Flags, fn conn ->
      if conn.method == "POST" do
        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{"InitialConfigurationToken" => "t0"})
      else
        conn
        |> Plug.Conn.put_resp_header("next-poll-configuration-token", "t1")
        |> Plug.Conn.send_resp(200, Jason.encode!(doc))
      end
    end)
  end

  defp put_env_restoring(app, key, value) do
    prev = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(app, key, v)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp system_env_restoring(vars) do
    prev = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)
    Enum.each(vars, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)

    on_exit(fn ->
      Enum.each(prev, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)
    end)
  end

  # Prod's shape: the migrate eval starts no app, and AppConfig is signed with
  # the ECS task role, which ex_aws resolves through its AuthCache (a table
  # the :ex_aws application owns) and the task-role endpoint. Red before: only
  # :req was started, the lookup raised, and the step ran despite `false`.
  test "in the migrate eval (ex_aws not started), a false flag read with the task role disables" do
    appconfig!(false)
    serve_flags!(%{"folder_path_hash_drop" => false})

    system_env_restoring([
      {"AWS_ACCESS_KEY_ID", nil},
      {"AWS_SECRET_ACCESS_KEY", nil},
      {"AWS_SESSION_TOKEN", nil},
      {"AWS_CONTAINER_CREDENTIALS_FULL_URI", nil},
      {"AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "/v2/credentials/test"}
    ])

    for k <- [:access_key_id, :secret_access_key, :security_token],
        do: put_env_restoring(:ex_aws, k, nil)

    # The task-role endpoint (169.254.170.2), answered through ex_aws's Req client.
    put_env_restoring(:ex_aws, :req_opts, plug: {Req.Test, ExAws.InstanceMeta})

    Req.Test.stub(ExAws.InstanceMeta, fn conn ->
      Req.Test.json(conn, %{
        "AccessKeyId" => "ASIATEST",
        "SecretAccessKey" => "secret",
        "Token" => "session",
        "Expiration" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
      })
    end)

    :ok = Application.stop(:ex_aws)
    # Restarted fresh: its AuthCache must not keep this test's task-role creds.
    on_exit(fn ->
      _ = Application.stop(:ex_aws)
      {:ok, _} = Application.ensure_all_started(:ex_aws)
    end)

    assert run() == :disabled
    assert present() == {1, 1}
  end

  test "the flags fetch process exits: the step runs with the default and returns" do
    appconfig!()
    Req.Test.stub(Engram.ServiceConfig.Flags, fn _conn -> exit(:boom) end)

    log = capture_log(fn -> assert run() == :done end)

    assert log =~ "folder_path_hash_drop flags unreadable"
    assert present() == {0, 0}
  end

  # As every flag-owned key the step reads only from the flags file: a DB
  # override would be silently ignored, so it is refused.
  test "a DB override of the kill switch is refused" do
    assert {:error, :managed_by_flags} =
             Engram.ServiceConfig.override(:folder_path_hash_drop, false, by: "t")
  end

  test "flags fetch times out: the step runs with the default and returns" do
    appconfig!()

    Req.Test.stub(Engram.ServiceConfig.Flags, fn conn ->
      Process.sleep(1_000)
      Req.Test.json(conn, %{"InitialConfigurationToken" => "t0"})
    end)

    log = capture_log(fn -> assert run(flags_timeout_ms: 100) == :done end)

    assert log =~ "folder_path_hash_drop flags unreadable"
    assert present() == {0, 0}
  end
end
