defmodule Engram.Repo.ShedError do
  @moduledoc """
  A request's tenant transaction ran past its own server-side bound
  (`statement_timeout`, SQLSTATE 57014, or `lock_timeout`, 55P03, set by
  `Engram.Repo.put_db_bounds/1`). Load, not a fault: a 429 the plugin retries
  after `retry-after` (`EngramWeb.Plugs.RetryAfter`), kept out of Sentry and the
  5xx alarm, the same contract as `Engram.Vaults.SeqGate.BusyError`.
  """
  defexception [:code, plug_status: 429]

  @impl true
  def message(%{code: code}), do: "database bound reached (#{code}), retry"
end
