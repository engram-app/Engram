defmodule Engram.Repo.Utc do
  @moduledoc """
  Time values that mean the same instant whether a column is
  `timestamp without time zone` (holding UTC wall time) or `timestamptz`,
  and whatever the session `TimeZone` is, so raw SQL written with them is
  correct before, during and after the `timestamp` -> `timestamptz`
  conversion.

  This does NOT make the UTC session pin (`Engram.RuntimeConfig.repo_parameters/1`)
  optional. Ecto's named prepared statements keep the parameter types they
  were prepared with, so a statement prepared against a `timestamp` column
  still binds a `timestamp` after the ALTER, converted in the session zone.
  The pin is load-bearing during and after the conversion; never remove it.

  Rules for raw SQL (enforced by `test/engram/repo/utc_session_test.exs`):

    * Write a UTC `DateTime`, bound uncast (`col = $1`, never `$1::timestamp`
      or `$1::timestamptz AT TIME ZONE 'UTC'`). Postgres types the parameter
      from the column, and Postgrex encodes a UTC `DateTime` exactly for both.
    * Compare against a bound UTC `DateTime`, not `now()`: `naive < now()`
      converts through the session TimeZone.
    * Read with `to_utc/1`: a raw read returns `NaiveDateTime` from a
      `timestamp` column and `DateTime` from a `timestamptz` one.
    * Day buckets and instants in SQL go through `utc_date/1` / `utc_instant/1`.
  """

  @doc "A raw-read timestamp as a UTC `DateTime`, whichever column type it came from."
  @spec to_utc(DateTime.t() | NaiveDateTime.t() | nil) :: DateTime.t() | nil
  def to_utc(nil), do: nil
  def to_utc(%DateTime{} = dt), do: DateTime.shift_zone!(dt, "Etc/UTC")
  def to_utc(%NaiveDateTime{} = dt), do: DateTime.from_naive!(dt, "Etc/UTC")

  # `extract(epoch FROM x)` counts a `timestamp` as UTC wall time and a
  # `timestamptz` as an instant, neither through the session TimeZone, and
  # `to_timestamp/1` turns the count back into a `timestamptz`. Double
  # precision: exact to the second, can round the last microsecond.
  @instant "to_timestamp(extract(epoch FROM ?))"

  @doc "SQL text: `expr` (either column type) as a `timestamptz`. For raw SQL strings."
  @spec instant_sql(String.t()) :: String.t()
  def instant_sql(expr), do: String.replace(@instant, "?", expr)

  @doc "Ecto: `expr` (either column type) as a `timestamptz` instant."
  defmacro utc_instant(expr) do
    quote do: fragment(unquote(@instant), unquote(expr))
  end

  @doc "Ecto: the UTC calendar date of `expr` (either column type)."
  defmacro utc_date(expr) do
    sql = "(#{@instant} AT TIME ZONE 'UTC')::date"
    quote do: fragment(unquote(sql), unquote(expr))
  end

  @doc """
  Ecto: `expr` (either column type) as UTC wall time (`timestamp`), for
  `type(..., :utc_datetime_usec)`, which Ecto casts to `timestamp`: a
  `timestamptz` cast there would go through the session TimeZone.
  """
  defmacro utc_wall(expr) do
    sql = "(#{@instant} AT TIME ZONE 'UTC')"
    quote do: fragment(unquote(sql), unquote(expr))
  end
end
