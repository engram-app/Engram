defmodule Engram.RepoSessionTimeoutsTest do
  # Guard: app connections carry an idle-in-transaction and a lock timeout, the
  # maintenance pool a longer idle bound only, and the migrator neither.
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

  test "the migrator drops the session parameters and keeps everything else" do
    config = [url: "ecto://x", pool_size: 3, parameters: RuntimeConfig.repo_parameters(:app)]

    assert Release.migrator_config(config) == [url: "ecto://x", pool_size: 3]
  end

  test "config/runtime.exs wires both pools" do
    source = File.read!(@runtime)
    assert source =~ "parameters: Engram.RuntimeConfig.repo_parameters(:app)"
    assert source =~ "parameters: Engram.RuntimeConfig.repo_parameters(:maintenance)"
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

      assert %{rows: [["1min"]]} =
               Postgrex.query!(conn, "SHOW idle_in_transaction_session_timeout", [])
    after
      GenServer.stop(conn)
    end
  end
end
