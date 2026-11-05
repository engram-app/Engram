defmodule Engram.FileTime do
  @moduledoc """
  The one normalizer for client file times (`notes.mtime` / `ctime`,
  `attachments.mtime`, `attachment_uploads.mtime`): an epoch number to the
  `*_at` timestamptz written beside it.

  Clients send epoch seconds, but prod holds milliseconds too (2026-11-05:
  `notes.mtime` min 1,776,072,500.9 s, max 1,793,442,859,572.0 ms). Below
  1e11 in magnitude is seconds (1e11 s is the year 5138), at or above it
  milliseconds (1e11 ms is 1973). `0` is the plugin's "unknown": NULL.
  Outside years 1 to 9999 is out of range, the caller's error.

  Phase expand: the doubles are still written exactly as sent; this fills
  the `*_at` columns beside them. Every writer goes through `put_at/3`
  (schema changesets) or `to_at!/1` (rows built for `insert_all` /
  `update_all`).
  """

  @ms_from 100_000_000_000

  @doc "`{:ok, DateTime | nil}`, or `{:error, :out_of_range}`."
  @spec to_at(number() | nil) :: {:ok, DateTime.t() | nil} | {:error, :out_of_range}
  def to_at(nil), do: {:ok, nil}
  def to_at(t) when t == 0, do: {:ok, nil}

  def to_at(t) when is_number(t) do
    us = if abs(t) < @ms_from, do: t * 1_000_000, else: t * 1_000

    case DateTime.from_unix(round(us), :microsecond) do
      {:ok, at} -> {:ok, at}
      {:error, _} -> {:error, :out_of_range}
    end
  end

  @doc "`to_at/1` for a time the server made or already validated; raises out of range."
  @spec to_at!(number() | nil) :: DateTime.t() | nil
  def to_at!(t) do
    {:ok, at} = to_at(t)
    at
  end

  @doc """
  When `changeset` changes `field`, puts its `to_at/1` in `at_field`, or an
  `"is out of range"` error on `field`.
  """
  @spec put_at(Ecto.Changeset.t(), atom(), atom()) :: Ecto.Changeset.t()
  def put_at(changeset, field, at_field) do
    case Ecto.Changeset.fetch_change(changeset, field) do
      {:ok, t} ->
        case to_at(t) do
          {:ok, at} -> Ecto.Changeset.put_change(changeset, at_field, at)
          {:error, :out_of_range} -> Ecto.Changeset.add_error(changeset, field, "is out of range")
        end

      :error ->
        changeset
    end
  end
end
