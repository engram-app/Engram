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
  `DateTime.to_unix(at) == trunc(t)` (payload hashes depend on it). Outside
  years 1 to 9999 is out of range.

  Strict only at the client boundary: `check/2` (REST params, 422) and
  `validate/2` (a request changeset). Every write behind it is lenient,
  `put_at/3`: a stored out-of-range double (a legacy row a move or restore
  copies) gets a NULL `*_at` and one log line, never a refused write.
  Rows built for `insert_all` / `update_all` use `to_at!/1` on values the
  server made or already checked.

  Phase expand: the doubles are still written exactly as sent. A previous
  release running during the rollout, or after a rollback, moves a double
  without its `*_at`, so migrate-data must recompute every row where
  `*_at IS DISTINCT FROM` the normalized double (not only NULL ones) and
  report how many it repaired: that count is the guard against a writer
  that skips the twin.
  """

  alias Engram.Logger.Metadata

  require Logger

  @ms_from 100_000_000_000
  # 0001-01-01T00:00:00Z; Postgres takes down to 4713 BC, Elixir to -9999,
  # so without this a negative millisecond value passes here and the write
  # fails in Postgres.
  @min_us -62_135_596_800_000_000

  @doc "`{:ok, DateTime | nil}`, or `{:error, :out_of_range}`."
  @spec to_at(number() | nil) :: {:ok, DateTime.t() | nil} | {:error, :out_of_range}
  def to_at(nil), do: {:ok, nil}
  def to_at(t) when t == 0, do: {:ok, nil}

  def to_at(t) when is_number(t) do
    us = if abs(t) < @ms_from, do: t * 1_000_000, else: t * 1_000

    us = floor(us)

    case us >= @min_us and DateTime.from_unix(us, :microsecond) do
      {:ok, at} -> {:ok, at}
      _ -> {:error, :out_of_range}
    end
  end

  @doc "`to_at/1` for a time the server made or already validated; raises out of range."
  @spec to_at!(number() | nil) :: DateTime.t() | nil
  def to_at!(t) do
    {:ok, at} = to_at(t)
    at
  end

  @doc """
  `:ok`, or `{:error, name}` for the first of `names` whose param is a
  number out of range: the client boundary (REST answers 422). Non-numbers
  are left to the changeset's cast.
  """
  @spec check(map(), [String.t()]) :: :ok | {:error, String.t()}
  def check(params, names) do
    Enum.find_value(names, :ok, fn name ->
      v = params[name]
      if is_number(v) and to_at(v) == {:error, :out_of_range}, do: {:error, name}
    end)
  end

  @doc "A request changeset's validator: `field` out of range is an error."
  @spec validate(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate(changeset, field) do
    Ecto.Changeset.validate_change(changeset, field, fn _, t ->
      if to_at(t) == {:error, :out_of_range}, do: [{field, "is out of range"}], else: []
    end)
  end

  @doc """
  When `changeset` changes `field`, puts its `to_at/1` in `at_field`. Out
  of range (checked at the client boundary, so only a stored legacy value
  gets here) is NULL plus one warning, never an error.
  """
  @spec put_at(Ecto.Changeset.t(), atom(), atom()) :: Ecto.Changeset.t()
  def put_at(changeset, field, at_field) do
    case Ecto.Changeset.fetch_change(changeset, field) do
      {:ok, t} ->
        case to_at(t) do
          {:ok, at} ->
            Ecto.Changeset.put_change(changeset, at_field, at)

          {:error, :out_of_range} ->
            Logger.warning(
              "file_time_out_of_range",
              Metadata.with_category(:warning, :data, field: field)
            )

            Ecto.Changeset.put_change(changeset, at_field, nil)
        end

      :error ->
        changeset
    end
  end
end
