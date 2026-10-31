defmodule EngramWeb.Plugs.StatementTimeout do
  @moduledoc """
  Picks the server-side `statement_timeout` for this request's tenant
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

  Values: `Engram.RuntimeConfig.statement_timeout/1`. Background work (Oban,
  channels, the maintenance pool) never passes through a plug, so it keeps
  the session default (none).
  """
  @behaviour Plug

  @impl true
  def init(class) when class in [:reset, :auth, :write], do: class

  @impl true
  def call(conn, :reset) do
    Engram.Repo.put_statement_timeout(nil)
    conn
  end

  def call(%Plug.Conn{method: method} = conn, :auth) when method in ["GET", "HEAD"],
    do: put(conn, :auth_read)

  def call(conn, _class), do: put(conn, :write)

  defp put(conn, class) do
    Engram.Repo.put_statement_timeout(Engram.RuntimeConfig.statement_timeout(class))
    conn
  end
end
