defmodule Engram.Search.FieldFilters do
  @moduledoc """
  Search filters on user-added frontmatter keys (2026-10-20 ruling): any key,
  exact (`eq`, `in`) or range (`gt`/`gte`/`lt`/`lte` on numbers and dates,
  `after`/`before` date windows). Each filter is `%{key, op, value}`.

  Key names resolve to the per-user `key_id` through the dictionary
  (`FrontmatterKeys.lookup/2`), one query per request for every filter. A key
  this user has never written is an explicit `{:unknown_field, key}`, never
  an empty result; a named field (`status`, `due`, ...) is
  `{:reserved_field, key}` (it has its own payload key, not `fa`). Every
  condition is nested (`Qdrant.attr_filter/2`), so the key and the value
  must match in the same entry.

  Values: a string or boolean `eq`/`in` is an exact match (its value filter
  id); a number compares `n`; an ISO date or datetime string compares `d`
  (unix seconds), and `eq` on a bare date matches that whole UTC day.
  """

  alias Engram.Notes.FrontmatterDate
  alias Engram.Notes.FrontmatterKeys
  alias Engram.Vector.FilterId
  alias Engram.Vector.Qdrant

  @ops ~w(eq in gt gte lt lte after before)
  @range_ops %{"gt" => :gt, "gte" => :gte, "lt" => :lt, "lte" => :lte}
  @day 86_400
  @max_filters 16

  @type filter :: %{required(String.t()) => term()} | %{required(atom()) => term()}
  @type error ::
          {:unknown_field, String.t()}
          | {:reserved_field, String.t()}
          | {:invalid_field_filter, String.t()}

  @doc """
  The Qdrant conditions for `filters`, or the first error. `filter_key` is
  the user's filter key (`Crypto.dek_filter_key/1`).
  """
  @spec to_conditions(Ecto.UUID.t(), binary(), [filter()]) :: {:ok, [map()]} | {:error, error()}
  def to_conditions(_user_id, _filter_key, []), do: {:ok, []}

  def to_conditions(_user_id, _filter_key, filters) when length(filters) > @max_filters,
    do: {:error, {:invalid_field_filter, "at most #{@max_filters} field filters"}}

  def to_conditions(user_id, filter_key, filters) do
    with {:ok, parsed} <- parse_all(filters) do
      hmacs = Map.new(parsed, fn {key, _op, _v} -> {key, FilterId.key_hmac(filter_key, key)} end)
      ids = FrontmatterKeys.lookup(user_id, Map.values(hmacs))

      Enum.reduce_while(parsed, {:ok, []}, fn {key, op, value}, {:ok, acc} ->
        with {:ok, key_id} <- key_id(ids, hmacs[key], key),
             {:ok, condition} <- condition(key_id, op, value, filter_key, key) do
          {:cont, {:ok, [condition | acc]}}
        else
          error -> {:halt, error}
        end
      end)
      |> then(fn
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        error -> error
      end)
    end
  end

  defp parse_all(filters) do
    Enum.reduce_while(filters, {:ok, []}, fn filter, {:ok, acc} ->
      case parse(filter) do
        {:ok, p} -> {:cont, {:ok, [p | acc]}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end)
  end

  defp parse(filter) when is_map(filter) do
    key = filter["key"] || filter[:key]
    op = to_string(filter["op"] || filter[:op] || "eq")
    value = Map.get(filter, "value", Map.get(filter, :value))

    cond do
      not (is_binary(key) and key != "") -> {:error, {:invalid_field_filter, inspect(key)}}
      reserved?(key) -> {:error, {:reserved_field, key}}
      op not in @ops -> {:error, {:invalid_field_filter, key}}
      true -> {:ok, {key, op, value}}
    end
  end

  defp parse(other), do: {:error, {:invalid_field_filter, inspect(other)}}

  @reserved MapSet.new(Enum.map(Map.keys(FrontmatterKeys.named()), &Atom.to_string/1))
  defp reserved?(key), do: MapSet.member?(@reserved, String.downcase(key))

  defp key_id(ids, hmac, key) do
    case Map.fetch(ids, hmac) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:unknown_field, key}}
    end
  end

  defp condition(id, "in", values, fk, key) when is_list(values) and values != [] do
    if Enum.all?(values, &exact?/1),
      do: {:ok, Qdrant.attr_filter(id, {:h, Enum.map(values, &value_id(fk, &1))})},
      else: in_values(id, values, fk, key)
  end

  defp condition(id, "eq", value, fk, key) do
    cond do
      is_number(value) -> {:ok, Qdrant.attr_filter(id, {:n, gte: value, lte: value})}
      day = date(value) -> {:ok, Qdrant.attr_filter(id, {:d, eq_window(value, day)})}
      exact?(value) -> {:ok, Qdrant.attr_filter(id, {:h, value_id(fk, value)})}
      true -> {:error, {:invalid_field_filter, key}}
    end
  end

  defp condition(id, op, value, _fk, key) when op in ~w(gt gte lt lte) do
    cond do
      is_number(value) -> {:ok, Qdrant.attr_filter(id, {:n, [{@range_ops[op], value}]})}
      t = date(value) -> {:ok, Qdrant.attr_filter(id, {:d, [{@range_ops[op], t}]})}
      true -> {:error, {:invalid_field_filter, key}}
    end
  end

  defp condition(id, op, value, _fk, key) when op in ~w(after before) do
    case date(value) do
      nil -> {:error, {:invalid_field_filter, key}}
      t -> {:ok, Qdrant.attr_filter(id, {:d, [{if(op == "after", do: :gte, else: :lte), t}]})}
    end
  end

  defp condition(_id, _op, _value, _fk, key), do: {:error, {:invalid_field_filter, key}}

  # A mixed `in` (numbers, dates and strings): any one of the eq conditions.
  defp in_values(id, values, fk, key) do
    values
    |> Enum.map(&condition(id, "eq", &1, fk, key))
    |> Enum.split_with(&match?({:ok, _}, &1))
    |> case do
      {ok, []} -> {:ok, %{should: Enum.map(ok, &elem(&1, 1))}}
      {_ok, [error | _]} -> error
    end
  end

  defp exact?(v), do: (is_binary(v) and v != "" and date(v) == nil) or is_boolean(v)

  defp value_id(fk, v), do: FilterId.attr_value(fk, to_string(v))

  # Same date rule as the indexing pass (`FrontmatterAttrs`): ISO-looking
  # strings only, a bare date is midnight UTC.
  defp date(<<_y::binary-size(4), ?-, _m::binary-size(2), ?-, _rest::binary>> = s) do
    case FrontmatterDate.parse(s, :lenient) do
      {unix, _date} -> unix
      nil -> nil
    end
  end

  defp date(_), do: nil

  defp eq_window(<<_::binary-size(10)>>, day), do: [gte: day, lte: day + @day - 1]
  defp eq_window(_datetime, t), do: [gte: t, lte: t]
end
