defmodule Engram.RepoSessionTimeoutsTest do
  # Guard: app connections carry an idle-in-transaction and a lock timeout, the
  # maintenance pool a longer idle bound only, and the migrator neither. Every
  # pool, the migrator and the dev/test config carry the UTC session pin.
  #
  # Prod's idle_in_transaction_session_timeout is the server default 24h and the
  # app set nothing (2026-10-20 audit, P1-12), so one stuck transaction could
  # hold locks and block vacuum for a day.
  use ExUnit.Case, async: true

  alias Engram.Release
  alias Engram.RuntimeConfig

  @runtime Path.join(__DIR__, "../../config/runtime.exs")

  test "the app pool bounds idle transactions and lock waits, and sets no statement_timeout" do
    params = RuntimeConfig.repo_parameters(:app)

    assert params[:idle_in_transaction_session_timeout] == "60s"
    assert params[:lock_timeout] == "10s"
    refute Keyword.has_key?(params, :statement_timeout)
  end

  test "the maintenance pool bounds idle transactions but never lock waits" do
    params = RuntimeConfig.repo_parameters(:maintenance)

    assert params[:idle_in_transaction_session_timeout]
    refute Keyword.has_key?(params, :lock_timeout)
    refute Keyword.has_key?(params, :statement_timeout)
  end

  test "the migrator drops the session timeouts, keeps UTC and everything else" do
    config = [url: "ecto://x", pool_size: 3, parameters: RuntimeConfig.repo_parameters(:app)]
    migrator = Release.migrator_config(config)

    assert migrator[:parameters] == [timezone: "UTC"]
    assert Keyword.delete(migrator, :parameters) == [url: "ecto://x", pool_size: 3]
  end

  # `timestamp` columns hold UTC wall time; any SQL converting between them
  # and `timestamptz` reads the session TimeZone, which a self-hosted server
  # can set to anything (staging's is America/Los_Angeles).
  test "every pool and the migrator run in UTC" do
    for pool <- [:app, :maintenance, :base] do
      assert RuntimeConfig.repo_parameters(pool)[:timezone] == "UTC", "#{pool}"
    end

    assert Release.migrator_config([])[:parameters][:timezone] == "UTC"
  end

  # The pin must reach every env, not only prod: `mix ecto.migrate` (dev, CI,
  # self-host from source) and the test suite connect with the dev/test
  # Repo config, and cached prepared statements keep `timestamp` parameter
  # types through the conversion, so each of them needs the UTC session.
  # Checked through the function runtime.exs calls, not by evaluating
  # runtime.exs (that reads and writes process env). The live test-env config
  # cannot prove it either: the `test` alias runs `engram.prepare_database`,
  # whose migrator session sets the pin on its own.
  test "the dev/test Repo config carries the UTC pin" do
    assert File.read!(@runtime) =~
             "config :engram, Engram.Repo, Engram.RuntimeConfig.dev_test_repo_opts(repo_conn)"

    assert RuntimeConfig.dev_test_repo_opts(database: "x")[:parameters] ==
             RuntimeConfig.repo_parameters(:base)

    assert RuntimeConfig.repo_parameters(:base) == [timezone: "UTC"]
  end

  # A server or role whose default zone is not UTC: the pin must override it.
  # A throwaway role with an America/Los_Angeles default, so nothing shared
  # changes; dropped on exit.
  test "the pin overrides a non-UTC role default" do
    base =
      Engram.Repo.config()
      |> Keyword.take([:hostname, :username, :password, :database, :port])

    role = "r27_tz_#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
    pw = Base.encode16(:crypto.strong_rand_bytes(12))

    # Registered first, so a failure between CREATE and the asserts still
    # drops the role.
    on_exit(fn ->
      {:ok, c} = Postgrex.start_link(base)
      Postgrex.query!(c, "DROP ROLE IF EXISTS #{role}", [])
      GenServer.stop(c)
    end)

    {:ok, admin} = Postgrex.start_link(base)
    Postgrex.query!(admin, "CREATE ROLE #{role} LOGIN PASSWORD '#{pw}'", [])
    Postgrex.query!(admin, "ALTER ROLE #{role} SET timezone = 'America/Los_Angeles'", [])
    GenServer.stop(admin)

    as_role = Keyword.merge(base, username: role, password: pw)

    zone = fn params ->
      {:ok, conn} = Postgrex.start_link(Keyword.put(as_role, :parameters, params))

      try do
        %{rows: [row]} =
          Postgrex.query!(
            conn,
            "SELECT current_setting('TimeZone'), source FROM pg_settings WHERE name = 'TimeZone'",
            []
          )

        row
      after
        GenServer.stop(conn)
      end
    end

    # Control: without the pin the role default wins.
    assert zone.([]) == ["America/Los_Angeles", "user"]

    for pool <- [:app, :maintenance, :base] do
      assert zone.(RuntimeConfig.repo_parameters(pool)) == ["UTC", "client"], "#{pool}"
    end
  end

  test "config/runtime.exs wires both pools" do
    source = File.read!(@runtime)
    assert source =~ "parameters: Engram.RuntimeConfig.repo_parameters(:app)"
    # The maintenance pool is built by RuntimeConfig.maintenance_repo_opts/3
    # (so its timeout wiring is testable); runtime.exs must call it, and it must
    # carry the maintenance session parameters.
    assert source =~ "Engram.RuntimeConfig.maintenance_repo_opts("

    assert RuntimeConfig.maintenance_repo_opts("ecto://x", 3, [])[:parameters] ==
             RuntimeConfig.repo_parameters(:maintenance)
  end

  # Proves Postgrex really applies the keyword list as session settings.
  test "a connection opened with the app parameters reports them" do
    opts =
      Engram.Repo.config()
      |> Keyword.take([:hostname, :username, :password, :database, :port])
      |> Keyword.put(:parameters, RuntimeConfig.repo_parameters(:app))

    {:ok, conn} = Postgrex.start_link(opts)

    try do
      assert %{rows: [["10s"]]} = Postgrex.query!(conn, "SHOW lock_timeout", [])
      # `client`: the value came from the startup packet, not a server that
      # happens to default to UTC.
      assert %{rows: [["UTC", "client"]]} =
               Postgrex.query!(
                 conn,
                 "SELECT setting, source FROM pg_settings WHERE name = 'TimeZone'",
                 []
               )

      assert %{rows: [["1min"]]} =
               Postgrex.query!(conn, "SHOW idle_in_transaction_session_timeout", [])
    after
      GenServer.stop(conn)
    end
  end
end
