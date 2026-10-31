defmodule EngramWeb.Plugs.StatementTimeout do
  @moduledoc """
  Picks the server-side `statement_timeout` and `lock_timeout` for this request's tenant
  transactions (`Engram.Repo.with_tenant/2` applies it with `SET LOCAL`, in
  the round trip that already sets the tenant).

    * `plug StatementTimeout, :reset` (endpoint): clears the previous
      request's class. A keep-alive connection serves many requests from one
      process, so a class left in the process would leak into the next one.
    * `plug StatementTimeout, :auth` (account, onboarding and billing scopes):
      reads (GET/HEAD) get the short `:auth_read` bound, so a lock convoy
      fails them fast instead of pinning a connection; writes there get
      `:write`.
    * `plug StatementTimeout, :write` (vault and MCP scopes): `:write`.
    * `plug StatementTimeout, :cascade` (in a controller, for the actions that
      run one cascading DELETE: account and vault delete/purge): `:cascade`.

  Values: `config :engram, :request_db_bounds` (`config/config.exs`), read via
  `Engram.RuntimeConfig.request_db_bounds/1`. A bound reached sheds as 429
  (`Engram.Repo.ShedError`). Background work (Oban,
  channels, the maintenance pool) never passes through a plug, so it keeps
  the session default (none).
  """
  @behaviour Plug

  @impl true
  def init(class) when class in [:reset, :auth, :write, :cascade], do: class

  @impl true
  def call(conn, :reset) do
    Engram.Repo.put_db_bounds(nil)
    conn
  end

  def call(%Plug.Conn{method: method} = conn, :auth) when method in ["GET", "HEAD"],
    do: put(conn, :auth_read)

  def call(conn, :cascade), do: put(conn, :cascade)
  def call(conn, _class), do: put(conn, :write)

  defp put(conn, class) do
    Engram.Repo.put_db_bounds(Engram.RuntimeConfig.request_db_bounds(class))
    conn
  end
end
