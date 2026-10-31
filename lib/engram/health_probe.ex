defmodule Engram.HealthProbe do
  @moduledoc """
  The readiness probe's own one-connection Postgres pool.

  `/api/health/deep` used to run `SELECT 1` on `Engram.Repo`. When one tenant's
  lock convoy drains that pool, the probe's checkout times out, the ALB marks
  the task unhealthy (3 misses at 15 s) and moves its traffic to the next task,
  which then drains too. Here the probe never waits behind requests, so it
  answers "is the database reachable", not "is the request pool idle". A dead
  database still fails it: the connection cannot reconnect and the query
  errors.

  Costs one connection per node. It connects lazily (`sync_connect` off), so a
  database that is down at boot does not stop the application starting.
  """

  @name __MODULE__

  def child_spec(_opts) do
    Engram.Application.repo_connection_opts()
    |> Keyword.merge(
      name: @name,
      pool_size: 1,
      # A probe arrives every few seconds and runs in milliseconds; a little
      # queueing between concurrent probes is fine, shedding them is not.
      queue_target: 500,
      queue_interval: 2_000,
      # Postgrex backs off up to 30 s between reconnects by default, which
      # would keep the probe red that long after an RDS failover the request
      # pool has already recovered from.
      backoff_max: 5_000
    )
    |> Postgrex.child_spec()
  end

  @doc "`:ok` when the database answers on the probe connection within 2 s."
  @spec check(GenServer.server()) :: :ok | {:error, Exception.t()}
  def check(conn \\ @name) do
    case Postgrex.query(conn, "SELECT 1", [], timeout: 2_000) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    # The probe pool itself is gone (not started, crashed): not ready.
    :exit, _ -> {:error, DBConnection.ConnectionError.exception("health probe unavailable")}
  end
end
