defmodule Engram.Notes.FrontmatterAttrs do
  @moduledoc """
  The long tail of v5 frontmatter filters (spec 3.3b): every top-level key
  that is not first-class, not an alias of one and not in the dense prefix.
  Strings and booleans become exact `{k, v}` HMAC pairs, numbers `{k, n}`,
  ISO dates and datetimes `{k, t}` (unix seconds; a bare date is midnight
  UTC). Keys and values are HMAC'd under the per-user filter key
  (`FilterId.key_hmac/2`, `FilterId.value_hmac/2`); the Qdrant payload
  formats them with `FilterId.from_hmac/1`, Postgres keeps them whole.

  Nested maps are skipped entirely (no `.` flattening); a list gives one
  entry per scalar element, at most 64 of them; a string over 256 bytes
  is skipped; each output list keeps at most 64 entries. Values are never
  logged.
  """

  alias Engram.Notes.OkfFields
  alias Engram.Vector.FilterId

  # First-class keys, their aliases (top-level heads of the nested ones) and
  # the dense-prefix keys.
  @skip MapSet.new(~w(type tags status author generated reviewed_by verified source resource
                      sources project created date updated modified timestamp reviewed
                      expires stale_after due priority title aliases description))

  @max_entries 64
  @max_string 256

  @type t :: %{
          attrs: [%{k: binary(), v: binary()}],
          nums: [%{k: binary(), n: float()}],
          dates: [%{k: binary(), t: integer()}]
        }

  @spec extract(map(), binary()) :: t()
  def extract(values, filter_key) do
    entries =
      values
      |> Enum.reject(fn {key, _} -> MapSet.member?(@skip, key) end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {key, value} -> entries(key, value) end)

    k = Map.new(entries, fn {key, _kind, _v} -> {key, FilterId.key_hmac(filter_key, key)} end)

    %{
      attrs: take(entries, :attr, &%{k: k[&1], v: FilterId.value_hmac(filter_key, &2)}),
      nums: take(entries, :num, &%{k: k[&1], n: &2}),
      dates: take(entries, :date, &%{k: k[&1], t: &2})
    }
  end

  defp take(entries, kind, build) do
    for({key, ^kind, v} <- entries, do: build.(key, v)) |> Enum.take(@max_entries)
  end

  defp entries(key, list) when is_list(list),
    do: list |> Enum.take(@max_entries) |> Enum.flat_map(&scalar(key, &1))

  defp entries(key, value), do: scalar(key, value)

  defp scalar(key, b) when is_boolean(b), do: [{key, :attr, to_string(b)}]
  defp scalar(key, n) when is_number(n), do: [{key, :num, n / 1}]

  defp scalar(key, s) when is_binary(s) and s != "" and byte_size(s) <= @max_string do
    case iso_date(s) do
      nil -> [{key, :attr, s}]
      unix -> [{key, :date, unix}]
    end
  end

  defp scalar(_key, _skipped), do: []

  # Only strings that look like a date pay the parse.
  defp iso_date(<<_y::binary-size(4), ?-, _m::binary-size(2), ?-, _rest::binary>> = s) do
    case OkfFields.parse_date_value(s, :lenient) do
      nil -> nil
      dt -> DateTime.to_unix(dt)
    end
  end

  defp iso_date(_s), do: nil
end
