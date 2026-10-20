defmodule Engram.IndexBudgetHelpers do
  @moduledoc """
  Turns on the v5 index budget (`Engram.Indexing.budget_enabled?/0`) for one
  test. It is off by default, in tests as in prod until the v5 pass, so a
  test that exercises caps, the floor or the 04:00 sweeps opts in with
  `setup :enable_index_budget`.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  def enable_index_budget(_ctx \\ %{}) do
    prev = Application.get_env(:engram, :index_budget_enabled)
    Application.put_env(:engram, :index_budget_enabled, true)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:engram, :index_budget_enabled),
        else: Application.put_env(:engram, :index_budget_enabled, prev)
    end)

    :ok
  end
end
