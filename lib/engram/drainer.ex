defmodule Engram.Drainer do
  @moduledoc """
  Graceful drain run from `Engram.Application.prep_stop/1` on SIGTERM.

  Order matters: stop pulling NEW work (Oban), let the ALB stop routing new
  requests (it already deregistered us), give in-flight work a short grace,
  then disconnect from peers so survivors observe a clean `nodedown` instead
  of a later `noproc`/`noconnection`. The Phoenix endpoint drains in-flight
  HTTP/WebSocket connections separately during supervisor teardown (Thousand
  Island shutdown_timeout + socket_drano).
  """

  alias Engram.Logger.Metadata

  require Logger

  @default_grace_ms 5_000

  @spec drain(keyword()) :: :ok
  def drain(opts \\ []) do
    pause_oban = Keyword.get(opts, :pause_oban, &default_pause_oban/0)
    peers = Keyword.get(opts, :peers, &Node.list/0)
    disconnect = Keyword.get(opts, :disconnect, &Node.disconnect/1)
    grace_ms = Keyword.get(opts, :grace_ms, @default_grace_ms)

    Logger.info(
      "drain: starting graceful shutdown",
      Metadata.with_category(:info, :lifecycle, [])
    )

    pause_oban.()
    if grace_ms > 0, do: Process.sleep(grace_ms)

    Enum.each(peers.(), fn node ->
      Logger.info(
        "drain: disconnecting peer #{inspect(node)}",
        Metadata.with_category(:info, :lifecycle, [])
      )

      disconnect.(node)
    end)

    :ok
  end

  defp default_pause_oban do
    # local_only: true is critical. Without it Oban broadcasts the pause over
    # the Postgres notifier to EVERY node sharing the instance, so a draining
    # task would pause queues fleet-wide — including freshly-booted tasks during
    # a rolling deploy, which then never resume. A draining node pauses only
    # itself; survivors keep processing.
    _ = oban_facade().pause_all_queues(Oban, local_only: true)
    :ok
  rescue
    e ->
      Logger.warning(
        "drain: oban pause skipped: #{inspect(e)}",
        Metadata.with_category(:warning, :lifecycle, [])
      )
  end

  defp oban_facade, do: Application.get_env(:engram, :oban_facade, Oban)
end
