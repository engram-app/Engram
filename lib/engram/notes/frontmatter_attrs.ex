defmodule Engram.Notes.FrontmatterAttrs do
  @moduledoc """
  The long tail of v5 frontmatter filters (spec 3.3b): every top-level key
  that is not first-class, not an alias of one and not in the dense prefix.
  Strings and booleans become exact `{k, v}` HMAC pairs, numbers `{k, n}`,
  ISO dates and datetimes `{k, t}` (unix seconds; a bare date is midnight
  UTC); numbers and dates are plaintext so they range. Keys are HMAC'd under
  the per-user filter key (`FilterId.key_hmac/2`) and mapped to a per-user
  `key_id` by `Engram.Notes.FrontmatterKeys` from `names` (key HMAC to the
  key as written, held in memory only); string values are HMAC'd too
  (`FilterId.value_hmac/2`).

  Nested maps are skipped entirely (no `.` flattening); a list gives one
  entry per scalar element, at most 64 of them; a string over 256 bytes
  is skipped; each output list keeps at most 64 entries. Values are never
  logged.
  """

  alias Engram.Notes.FrontmatterDate
  alias Engram.Notes.KeyAliases
  alias Engram.Vector.FilterId

  @max_entries 64
  @max_string 256

  @type t :: %{
          attrs: [%{k: binary(), v: binary()}],
          nums: [%{k: binary(), n: float()}],
          dates: [%{k: binary(), t: integer()}],
          names: %{binary() => String.t()}
        }

  @spec extract(map(), binary()) :: t()
  def extract(values, filter_key) do
    entries =
      values
      # First-class keys, their English aliases and the dense-prefix keys:
      # the shared field table (`KeyAliases.english/0`), so a field added
      # there is never also indexed as a user-added key.
      |> Enum.reject(fn {key, _} ->
        MapSet.member?(KeyAliases.english(), String.downcase(key))
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {key, value} -> entries(key, value) end)

    k = Map.new(entries, fn {key, _kind, _v} -> {key, FilterId.key_hmac(filter_key, key)} end)

    attrs = take(entries, :attr, &%{k: k[&1], v: FilterId.value_hmac(filter_key, &2)})
    nums = take(entries, :num, &%{k: k[&1], n: &2})
    dates = take(entries, :date, &%{k: k[&1], t: &2})
    used = MapSet.new(attrs ++ nums ++ dates, & &1.k)

    # First spelling wins when two keys fold together (`Mood`, `mood`).
    names =
      Enum.reduce(entries, %{}, fn {key, _kind, _v}, acc ->
        if MapSet.member?(used, k[key]), do: Map.put_new(acc, k[key], key), else: acc
      end)

    %{attrs: attrs, nums: nums, dates: dates, names: names}
  end

  defp take(entries, kind, build) do
    for({key, ^kind, v} <- entries, do: build.(key, v)) |> Enum.take(@max_entries)
  end

  defp entries(key, list) when is_list(list),
    do: list |> Enum.take(@max_entries) |> Enum.flat_map(&scalar(key, &1))

  defp entries(key, value), do: scalar(key, value)

  defp scalar(key, b) when is_boolean(b), do: [{key, :attr, to_string(b)}]

  defp scalar(key, n) when is_number(n) do
    case number(n) do
      nil -> scalar(key, Integer.to_string(n))
      f -> [{key, :num, f}]
    end
  end

  defp scalar(key, s) when is_binary(s) and s != "" and byte_size(s) <= @max_string do
    case iso_date(s) do
      nil -> [{key, :attr, s}]
      unix -> [{key, :date, unix}]
    end
  end

  defp scalar(_key, _skipped), do: []

  # Only strings that look like a date pay the parse.
  defp iso_date(<<_y::binary-size(4), ?-, _m::binary-size(2), ?-, _rest::binary>> = s) do
    case FrontmatterDate.parse(s, :lenient) do
      nil -> nil
      {unix, _date} -> unix
    end
  end

  defp iso_date(_s), do: nil

  @doc """
  A frontmatter number as a float, or nil. An integer outside the float
  range (a YAML bignum such as a 400-digit id) is not a number here: `/ 1`
  would raise and crash the indexing pass. YAML `.inf`/`.nan` arrive as
  strings and are not numbers either.
  """
  @spec number(term()) :: float() | nil
  def number(n) when is_float(n), do: n
  def number(n) when is_integer(n) and abs(n) < 1.0e308, do: n / 1
  def number(_), do: nil
end
