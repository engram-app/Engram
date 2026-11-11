defmodule Engram.LockTimeoutRepo do
  @moduledoc """
  A repo for migration lock-retry tests: `Engram.Repo`, except that the next
  `refuse/1` statements given to `query!/3` raise a 55P03 lock timeout
  (`:lock_not_available`) before any reach the database. `query!/1` (the
  `SET` / `RESET lock_timeout` around them) always passes through.
  """

  @key {__MODULE__, :left}

  @doc "Refuse the next `n` statements. Call from the test; `async: false` only."
  def refuse(n), do: :persistent_term.put(@key, n)

  @doc "How many refusals are still pending."
  def left, do: :persistent_term.get(@key, 0)

  def checkout(fun, opts), do: Engram.Repo.checkout(fun, opts)
  defdelegate query!(sql), to: Engram.Repo

  def query!(sql, params, opts) do
    case left() do
      n when n > 0 ->
        refuse(n - 1)

        raise %Postgrex.Error{
          postgres: %{
            code: :lock_not_available,
            pg_code: "55P03",
            severity: "ERROR",
            message: "lock timeout"
          }
        }

      _ ->
        Engram.Repo.query!(sql, params, opts)
    end
  end
end
