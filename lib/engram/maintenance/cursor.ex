defmodule Engram.Maintenance.Cursor do
  @moduledoc """
  The persisted resume point of a bounded maintenance sweep (table
  `maintenance_cursors`, one row per `name`). A sweep that caps its rows per
  run reads from its cursor, stores the last key it reached, and calls
  `reset/1` when a run came back short (it reached the end: the next run
  wraps to the start). Survives deploys and Cron leader changes, unlike the
  node-local walk cursors of `Engram.Backfill.IdWindows`.

  `cursor` is a small JSON map of keys (ids, never content). Not a tenant
  table (absent from `Engram.Repo.tenant_tables/0`, no RLS): a row belongs to
  a sweep, not to a user, and only the sweeps read it.
  """

  import Ecto.Query

  alias Engram.Repo

  @doc "The stored cursor of `name`, or nil (start from the beginning)."
  @spec get(String.t()) :: map() | nil
  def get(name) do
    Repo.one(from(c in "maintenance_cursors", where: c.name == ^name, select: c.cursor))
  end

  @doc "Stores `cursor` as `name`'s resume point."
  @spec put(String.t(), map()) :: :ok
  def put(name, %{} = cursor) do
    {_, _} =
      Repo.insert_all(
        "maintenance_cursors",
        [%{name: name, cursor: cursor, updated_at: DateTime.utc_now()}],
        on_conflict: {:replace, [:cursor, :updated_at]},
        conflict_target: :name
      )

    :ok
  end

  @doc "Forgets `name`'s cursor: the next run starts at the beginning."
  @spec reset(String.t()) :: :ok
  def reset(name) do
    {_, _} = Repo.delete_all(from(c in "maintenance_cursors", where: c.name == ^name))
    :ok
  end

  @doc "Deletes `name` only while it still holds `value`; true when it did."
  @spec reset_if(String.t(), map()) :: boolean()
  def reset_if(name, %{} = value) do
    {n, _} =
      Repo.delete_all(
        from(c in "maintenance_cursors",
          where: c.name == ^name and c.cursor == type(^value, :map)
        )
      )

    n == 1
  end

  @doc """
  `put/2` when a run filled its cap (`size == cap`, more may follow), else
  `reset/1` (the run reached the end).
  """
  @spec advance(String.t(), map() | nil, non_neg_integer(), pos_integer()) :: :ok
  def advance(name, last, size, cap) when size >= cap and is_map(last), do: put(name, last)
  def advance(name, _last, _size, _cap), do: reset(name)
end
