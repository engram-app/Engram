defmodule Engram.Notes.EffectiveDates do
  @moduledoc """
  A note's effective `updated` / `created` dates (unix seconds): the
  frontmatter date when it has one (`FlatFields.dates/1`, the one date
  parser), else the file time (`mtime` / `ctime` through `Engram.FileTime`),
  else the row's `updated_at` / `created_at`. The one place that
  fallback is decided:

    * `updated/2` / `created/2`: the reference the SQL is pinned to (no
      point carries a date since R3a; it lives in Postgres only).
    * `stored/2`: the frontmatter-or-file part, which the content save stores
      in `notes.eff_updated` / `eff_created` (`Note.changeset/2`), computed
      by this module, never reparsed in SQL.
    * `updated_sql/1` / `created_sql/1`: the note filter's date ranges,
      `COALESCE(stored column, row time)`, the expression the indexes
      `notes_eff_updated_live` / `notes_eff_created_live` are built on
      (`index_sql/1`; Postgres uses an expression index only for an identical
      expression). SQL only adds the row-time fallback: no parsing, no
      arithmetic on client numbers.

  `effective_dates_parity_test.exs` pins the SQL to `updated/2` /
  `created/2` and the migrated indexes to `index_sql/1`.

  `updated/2` / `created/2` return `{unix, source}`: `source` is nil for the
  frontmatter, `1` for the file time, `2` for the row time.
  """

  alias Engram.FileTime

  @file_src 1
  @server_src 2

  # `engram_epoch_s/1` (migration 20261105150100): whole unix seconds of a
  # row time, IMMUTABLE so an index can use it, overloaded for `timestamp`
  # and `timestamptz`. `notes.updated_at` / `created_at` move to timestamptz
  # (`Engram.Repo.Utc`); ALTER COLUMN TYPE rebuilds the indexes from their
  # text and picks the other overload, so the indexes need no change then.
  @updated_sql "COALESCE(?, engram_epoch_s(?))"
  @updated_cols ~w(eff_updated updated_at)

  @created_sql "COALESCE(?, engram_epoch_s(?))"
  @created_cols ~w(eff_created created_at)

  @typedoc "`{unix seconds, source}` (see the moduledoc)."
  @type t :: {integer() | nil, nil | 1 | 2}

  # No @spec on the functions below: a contract here made `:underspecs`
  # flag their callers on CI.

  @doc """
  The stored part of an effective date: the frontmatter date `fm`, else the
  file time `t` in whole seconds when above 0, else nil (the row time then
  applies). Units follow `Engram.FileTime` (the one normalizer: milliseconds
  to seconds, out of range is unknown); a seconds value is `trunc(t)`.

  `stored/2` itself takes the double (the write side: `eff_created` /
  `eff_updated` are derived from what the client sent). `updated/2` and
  `created/2` read through `FileTime.mtime/1` / `ctime/1`, which since the
  R25 read switch serve the `*_at` twin's instant. The two agree on every
  row `FileTime.put_at/3` wrote and the backfill healed; the write side
  moves to `*_at` when the doubles go.
  """
  def stored(fm, _t) when is_integer(fm), do: fm

  # Seconds (all of prod's `ctime` and all but 3 `mtime` rows): main's
  # payload formula verbatim, `trunc(t)` behind `t > 0`, so a payload hash
  # cannot move by construction. Milliseconds: `FileTime` (they move once,
  # out of the year 58,000).
  def stored(nil, t) when is_number(t) and t > 0 do
    if FileTime.seconds?(t) do
      trunc(t)
    else
      case FileTime.to_at(t) do
        {:ok, %DateTime{} = at} -> DateTime.to_unix(at)
        _ -> nil
      end
    end
  end

  def stored(nil, _t), do: nil

  @doc "Effective updated date. `fm` is the frontmatter's (nil when absent)."
  def updated(_note, fm) when is_integer(fm), do: {fm, nil}

  # The row time is read only when there is no file time: callers building
  # a payload from a partial map need not carry it.
  def updated(note, nil) do
    case stored(nil, FileTime.mtime(note)) do
      nil -> {unix(note.updated_at), @server_src}
      file -> {file, @file_src}
    end
  end

  @doc "Effective created date. `fm` is the frontmatter's (nil when absent)."
  def created(_note, fm) when is_integer(fm), do: {fm, nil}

  def created(note, nil) do
    case stored(nil, FileTime.ctime(note)) do
      nil -> {unix(note.created_at), @server_src}
      file -> {file, @file_src}
    end
  end

  @doc "`updated/2` in SQL over the note binding `n`, for an Ecto query."
  defmacro updated_sql(n) do
    sql = @updated_sql

    quote do
      fragment(unquote(sql), unquote(n).eff_updated, unquote(n).updated_at)
    end
  end

  @doc "`created/2` in SQL over the note binding `n`, for an Ecto query."
  defmacro created_sql(n) do
    sql = @created_sql

    quote do
      fragment(unquote(sql), unquote(n).eff_created, unquote(n).created_at)
    end
  end

  @doc "The same expression over bare column names: what the index is built on."
  @spec index_sql(:updated | :created) :: String.t()
  def index_sql(:updated), do: fill(@updated_sql, @updated_cols)
  def index_sql(:created), do: fill(@created_sql, @created_cols)

  @doc """
  The columns the index INCLUDEs: the answer (`id`, `user_id` for RLS) and
  the expression's own columns, which an index-only scan needs.
  """
  # No @spec: a constant, and `:underspecs` flags `[String.t()]` against it.
  def index_include(:updated), do: ~w(id user_id) ++ @updated_cols
  def index_include(:created), do: ~w(id user_id) ++ @created_cols

  defp fill(sql, cols),
    do: Enum.reduce(cols, sql, &String.replace(&2, "?", &1, global: false))

  defp unix(nil), do: nil
  defp unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
end
