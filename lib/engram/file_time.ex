defmodule Engram.FileTime do
  @moduledoc """
  The one normalizer for client file times (`notes.mtime` / `ctime`,
  `attachments.mtime`, `attachment_uploads.mtime`): an epoch number to the
  `*_at` timestamptz written beside it.

  Clients send epoch seconds, but prod holds milliseconds too (2026-11-05:
  `notes.mtime` min 1,776,072,500.9 s, max 1,793,442,859,572.0 ms). Below
  1e11 in magnitude is seconds (1e11 s is the year 5138), at or above it
  milliseconds (1e11 ms is 1973). `0` is the plugin's "unknown": NULL.
  Floored to the microsecond, never rounded, so a seconds value keeps
  `DateTime.to_unix(at) == trunc(t)` (payload hashes depend on it). Floor
  equals trunc only for `t >= 0`, which is all the payload hash reads. Outside
  years 1 to 9999 is out of range.

  Strict only at the client boundary: `check/2` (REST params, 422) and
  `validate/2` (a request changeset). Every write behind it is lenient,
  `put_at/3`: a stored out-of-range double (a legacy row a move or restore
  copies) gets a NULL `*_at` and one log line, never a refused write.
  Rows built for `insert_all` / `update_all` use `to_at!/1` on values the
  server made or already checked.

  Phase migrate-data (R25): readers go through `epoch/2` (`mtime/1`,
  `ctime/1`), which still derives from the double, the fresher value until
  contract; `put_at/3` repairs a stale twin on every write, and
  `Engram.DataMigrations.FileTimes` backfills the rest.

  Phase expand: the doubles are still written exactly as sent. A previous
  release running during the rollout, or after a rollback, moves a double
  without its `*_at`, so migrate-data must recompute every row where
  `*_at IS DISTINCT FROM` the normalized double (not only NULL ones) and
  report how many it repaired: that count is the guard against a writer
  that skips the twin. It must normalize with this module (or the same
  floor and bounds in SQL; never `to_timestamp`, which rounds to the
  microsecond), and count out-of-range legacy rows separately instead of
  aborting the batch.
  """

  alias Engram.Logger.Metadata

  require Logger

  @ms_from 100_000_000_000
  @max_abs 1.0e16
  # 0001-01-01T00:00:00Z; Postgres takes down to 4713 BC, Elixir to -9999,
  # so without this a negative millisecond value passes here and the write
  # fails in Postgres.
  @min_us -62_135_596_800_000_000

  @doc "Whether `t` is in seconds (below 1e11 in magnitude), not milliseconds."
  @spec seconds?(number()) :: boolean()
  def seconds?(t) when is_number(t), do: abs(t) < @ms_from

  @doc "`{:ok, DateTime | nil}`, or `{:error, :out_of_range}`."
  @spec to_at(number() | nil) :: {:ok, DateTime.t() | nil} | {:error, :out_of_range}
  def to_at(nil), do: {:ok, nil}
  def to_at(t) when t == 0, do: {:ok, nil}
  # Past year 9999 even as milliseconds (2.5e14), and the scaling below
  # would overflow a double near 1e302.
  def to_at(t) when is_number(t) and abs(t) > @max_abs, do: {:error, :out_of_range}

  def to_at(t) when is_number(t) do
    us = if abs(t) < @ms_from, do: t * 1_000_000, else: t * 1_000

    us = floor(us)

    case us >= @min_us and DateTime.from_unix(us, :microsecond) do
      {:ok, at} -> {:ok, at}
      _ -> {:error, :out_of_range}
    end
  end

  @doc """
  `to_at/1`, lenient: out of range is NULL. The one "what the twin should
  hold" for every writer and the backfill.
  """
  @spec normalize(number() | nil) :: DateTime.t() | nil
  def normalize(t) do
    case to_at(t) do
      {:ok, at} -> at
      {:error, :out_of_range} -> nil
    end
  end

  @doc "True when two `*_at` values are the same instant (or both NULL)."
  @spec same_at?(DateTime.t() | nil, DateTime.t() | nil) :: boolean()
  def same_at?(nil, nil), do: true
  def same_at?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq
  def same_at?(_, _), do: false

  @doc """
  The epoch-seconds number a reader sends, given the `*_at` column `at` and
  the stored double `t`. The wire format is unchanged.

  During migrate-data the DOUBLE is the fresher value: every release writes
  it, and the twin is derived from it (a release before expand moves the
  double alone and leaves a stale twin). So the value comes from the double,
  normalized: a seconds double goes out bit-identical (payload hashes and
  client comparisons depend on it), a millisecond double goes out as its
  seconds, `0` and out of range go out as stored. `at` is read only when
  there is no double (after contract drops it).
  """
  @spec epoch(DateTime.t() | nil, number() | nil) :: number() | nil
  def epoch(at, nil), do: at && seconds(at)

  def epoch(_at, t), do: if(ms?(t), do: seconds(normalize(t)), else: t)

  @doc """
  True for an in-range double in milliseconds: the one value whose served
  seconds differ from the stored number (`epoch/2`).
  """
  @spec ms?(number() | nil) :: boolean()
  def ms?(t), do: is_number(t) and abs(t) >= @ms_from and normalize(t) != nil

  defp seconds(at), do: DateTime.to_unix(at, :microsecond) / 1_000_000

  @doc "`epoch/2` of a row's (or map's) `mtime_at` and `mtime`."
  @spec mtime(map()) :: number() | nil
  def mtime(row), do: epoch(Map.get(row, :mtime_at), Map.get(row, :mtime))

  @doc "`epoch/2` of a note's `ctime_at` and `ctime`."
  @spec ctime(map()) :: number() | nil
  def ctime(row), do: epoch(Map.get(row, :ctime_at), Map.get(row, :ctime))

  @doc "`to_at/1` for a time the server made or already validated; raises out of range."
  @spec to_at!(number() | nil) :: DateTime.t() | nil
  def to_at!(t) do
    {:ok, at} = to_at(t)
    at
  end

  @doc """
  `:ok`, or `{:error, name}` for the first of `names` whose param is out of
  range: the client boundary (REST answers 422). The param is read as the
  double column's own cast reads it (`Ecto.Type.cast(:float, _)`, so a
  numeric string counts); anything that cast refuses is left to it.
  """
  @spec check(map(), [String.t()]) :: :ok | {:error, String.t()}
  def check(params, names) do
    Enum.find_value(names, :ok, fn name ->
      with {:ok, t} when is_float(t) <- cast(params[name]),
           {:error, :out_of_range} <- to_at(t) do
        {:error, name}
      else
        _ -> nil
      end
    end)
  end

  # An integer past the largest double (a JSON `1e400` written out) makes
  # the float cast raise; it is out of range, not a 500.
  defp cast(v) when is_integer(v) and abs(v) > 1.0e308, do: {:ok, 1.0e308}
  defp cast(v), do: Ecto.Type.cast(:float, v)

  @doc "A request changeset's validator: `field` out of range is an error."
  @spec validate(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate(changeset, field) do
    Ecto.Changeset.validate_change(changeset, field, fn _, t ->
      if to_at(t) == {:error, :out_of_range}, do: [{field, "is out of range"}], else: []
    end)
  end

  @doc """
  Puts `normalize/1` of `field` in `at_field` whenever it differs from the
  stored twin: on a change of `field`, and on any write that carries an
  unchanged double over a stale twin (a pre-expand writer moved the double
  alone), so every write heals. Out of range (checked at the client
  boundary, so only a stored legacy value gets here) is NULL plus one
  warning, never an error.
  """
  @spec put_at(Ecto.Changeset.t(), atom(), atom()) :: Ecto.Changeset.t()
  def put_at(changeset, field, at_field) do
    t = Ecto.Changeset.get_field(changeset, field)
    at = normalize(t)

    if same_at?(at, Ecto.Changeset.get_field(changeset, at_field)) do
      changeset
    else
      if match?({:error, _}, to_at(t)) do
        Logger.warning(
          "file_time_out_of_range",
          Metadata.with_category(:warning, :data, field: field)
        )
      end

      Ecto.Changeset.put_change(changeset, at_field, at)
    end
  end
end
