defmodule Engram.Repo.ShedError do
  @moduledoc """
  A request's tenant transaction ran past its own server-side bound, set by
  `Engram.Repo.put_db_bounds/1`. Raised by `Engram.Repo.shed_on_bound/1` and
  counted (`[:engram, :repo, :shed]`, `code` + route `class`).

    * `:lock_not_available` (55P03, `lock_timeout`): the request waited on a
      lock held by other writers. Load: 429 with a short `retry-after`
      (`EngramWeb.Plugs.RetryAfter`), which the plugin waits out and retries.
    * `:query_canceled` (57014, `statement_timeout`): the statement itself ran
      too long. Often deterministic (a big vault, a bad plan), so retrying
      every few seconds would loop forever: 503 with NO `retry-after`, which
      the plugin counts toward parking the request.

  Neither is a server error to Sentry or the error log
  (`Engram.Sentry.EventFilter.server_error?/1`): both are logged at warning
  and counted, like `Engram.Vaults.SeqGate.BusyError`.
  """
  defexception [:code]

  @impl true
  def message(%{code: code}), do: "database bound reached (#{code})"

  defimpl Plug.Exception do
    def status(%{code: :lock_not_available}), do: 429
    def status(_), do: 503
    def actions(_), do: []
  end
end
