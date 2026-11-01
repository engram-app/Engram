defmodule Engram.RepoMaxLifetimeTest do
  # Proves DBConnection's `:max_lifetime` (wired by
  # `Engram.RuntimeConfig.repo_max_lifetime/1`) really recycles the Postgres
  # backend, and never mid-checkout. The test Repo runs on the Sandbox pool,
  # where the option does nothing, so this starts standalone one-connection
  # pools. `0..0` cannot be used: the pool checks age on the connection's
  # first checkin after connecting, so it would reconnect forever.
  use ExUnit.Case, async: true

  @lifetime_ms 1_000

  defp start_pool(extra) do
    opts = Engram.Application.repo_connection_opts() ++ [pool_size: 1] ++ extra
    start_supervised!({Postgrex, opts}, id: make_ref())
  end

  # pid plus start time, so an OS pid reused by a later backend still differs.
  defp backend_pid(conn) do
    %{rows: [[pid, started]]} =
      Postgrex.query!(
        conn,
        "SELECT pid, backend_start FROM pg_stat_activity WHERE pid = pg_backend_pid()",
        []
      )

    {pid, started}
  end

  test "max_lifetime recycles the backend on checkin, never mid-transaction" do
    pool = start_pool(max_lifetime: @lifetime_ms..@lifetime_ms)

    # One checkout that outlives the bound: same backend on both sides of it.
    # No timing dependency on when this checkout lands: the age counts from
    # connect, and the checkout alone holds it for longer than the bound, so
    # the connection is always expired by the checkin below.
    {:ok, {a, b}} =
      Postgrex.transaction(pool, fn c ->
        first = backend_pid(c)
        Process.sleep(@lifetime_ms + 200)
        {first, backend_pid(c)}
      end)

    assert a == b

    # After the checkin the pool reconnected: a new backend.
    refute backend_pid(pool) == a
  end

  test "control: without max_lifetime the backend survives checkins" do
    pool = start_pool([])
    assert backend_pid(pool) == backend_pid(pool)
  end
end
