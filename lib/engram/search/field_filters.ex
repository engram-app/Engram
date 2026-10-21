defmodule Engram.Search.FieldFilters do
  @moduledoc """
  Search filters on any frontmatter key (2026-10-20 rulings): each filter is
  `%{key, op, value}` with `op` one of `eq` (default), `in`, `gt`, `gte`,
  `lt`, `lte`, `after`, `before`. Available only once the v5 payload format
  AND the v5 layout are on (`available?/0`); before that every `fields`
  request is an explicit error, never an empty result.

  **Named fields** (and their aliases) route to the payload keys v5 already
  writes: `type`, `tags`, `status`, `author`, `reviewed_by`, `source` (alias
  `resource`, `sources`) and `project` match exactly; `created` (`date`),
  `updated` (`timestamp`, `modified`), `reviewed`, `expires`
  (`stale_after`), `due` and `priority` range. `status: stable` is the
  default and stored as no key, so it matches a missing `s`. `title`,
  `aliases`, `description`, `generated` and `verified` have no filter.

  **User-added keys** resolve to the per-user `key_id` through the dictionary
  (`FrontmatterKeys.lookup/2`), one query per request for every filter, and
  become nested `fa` conditions (key and value in the SAME entry). A key this
  user never wrote is `{:unknown_field, key}`; while the account is at its
  key limit it may have been skipped, so it is `{:field_not_indexed, key}`.

  Values: a string or boolean is an exact match; a number compares as a
  number (a quoted YAML number is a string and matches as one); an ISO date
  or datetime compares as a date. Date bounds: a bare date is the whole UTC
  day, so `eq` matches that day, `after`/`gte` start at it, `before`/`lt`
  end before it, `gt` starts the next day and `lte` ends with it; a
  datetime bound is that instant (`after` is `>=`, `before` is `<`).
  """

  alias Engram.Crypto
  alias Engram.Notes.FrontmatterDate
  alias Engram.Notes.FrontmatterKeys
  alias Engram.Notes.OkfFields
  alias Engram.Vector.FilterId
  alias Engram.Vector.PayloadKeys
  alias Engram.Vector.Qdrant

  @ops ~w(eq in gt gte lt lte after before)
  @range_ops %{"gt" => :gt, "gte" => :gte, "lt" => :lt, "lte" => :lte}
  @day 86_400
  @max_filters 16
  @max_in 100
  @max_echo 64

  # Named field (or alias) -> how it filters.
  @named %{
    "type" => :type,
    "tags" => :tags,
    "status" => {:exact, :status_id},
    "author" => {:exact, :author_id},
    "reviewed_by" => {:exact, :rev_by_id},
    "project" => {:exact, :proj_id},
    "source" => {:exact, :src_id},
    "resource" => {:exact, :src_id},
    "sources" => {:exact, :src_id},
    "created" => {:date, :fm_created},
    "date" => {:date, :fm_created},
    "updated" => {:date, :fm_timestamp},
    "timestamp" => {:date, :fm_timestamp},
    "modified" => {:date, :fm_timestamp},
    "reviewed" => {:date, :fm_reviewed},
    "expires" => {:day, :fm_expires},
    "stale_after" => {:day, :fm_expires},
    "due" => {:day, :fm_due},
    "priority" => {:num, :fm_priority}
  }

  @unfilterable MapSet.new(~w(title aliases description generated verified))

  @type error ::
          {:unknown_field, String.t()}
          | {:field_not_indexed, String.t()}
          | {:reserved_field, String.t()}
          | {:invalid_field_filter, String.t()}
          | {:too_many_field_filters, pos_integer()}
          | :field_filters_unavailable

  @doc "Field filters work only once the v5 payload format and the v5 layout are both on."
  @spec available?() :: boolean()
  def available?, do: Qdrant.v5_payload_format?() and Qdrant.write_v5_layout?()

  @doc "Longest key echoed back in an error message."
  def max_echo, do: @max_echo

  @doc """
  The Qdrant conditions for `filters`, or the first error. `filter_key` is
  the user's filter key (`Crypto.dek_filter_key/1`).
  """
  @spec to_conditions(Ecto.UUID.t(), binary(), [map()]) :: {:ok, [map()]} | {:error, error()}
  def to_conditions(_user_id, _filter_key, []), do: {:ok, []}

  def to_conditions(_user_id, _filter_key, filters) when length(filters) > @max_filters,
    do: {:error, {:too_many_field_filters, @max_filters}}

  def to_conditions(user_id, filter_key, filters) do
    with {:ok, parsed} <- collect(filters, &parse/1) do
      user_keys = for {{:user, key}, _op, _v} <- parsed, do: key
      hmacs = Map.new(user_keys, &{&1, FilterId.key_hmac(filter_key, &1)})
      ids = FrontmatterKeys.lookup(user_id, Map.values(hmacs))
      ctx = %{fk: filter_key, ids: ids, hmacs: hmacs, user_id: user_id}

      collect(parsed, fn {field, op, value} -> condition(field, op, value, ctx) end)
    end
  end

  defp collect(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
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
      not (is_binary(key) and key != "") -> {:error, {:invalid_field_filter, echo(inspect(key))}}
      op not in @ops -> {:error, {:invalid_field_filter, echo(key)}}
      op == "in" and not (is_list(value) and value != []) -> invalid(key)
      op == "in" and length(value) > @max_in -> invalid(key)
      true -> field(key, op, value)
    end
  end

  defp parse(other), do: {:error, {:invalid_field_filter, echo(inspect(other))}}

  defp field(key, op, value) do
    lower = String.downcase(key)

    cond do
      Map.has_key?(@named, lower) -> {:ok, {{:named, @named[lower], key}, op, value}}
      MapSet.member?(@unfilterable, lower) -> {:error, {:reserved_field, echo(key)}}
      true -> {:ok, {{:user, key}, op, value}}
    end
  end

  # -- named fields ---------------------------------------------------------

  defp condition({:named, :type, key}, op, value, ctx) do
    with {:ok, values} <- exact_values(op, value, key) do
      ids = Enum.map(values, &type_b64(ctx.fk, &1))
      {:ok, Qdrant.match_filter(:type, if(op == "in", do: ids, else: hd(ids)))}
    end
  end

  defp condition({:named, :tags, key}, op, value, ctx) do
    with {:ok, values} <- exact_values(op, value, key) do
      tags = Enum.map(values, &Base.encode64(Crypto.hmac_field(ctx.fk, to_string(&1))))
      {:ok, Qdrant.match_filter(:tags, tags)}
    end
  end

  defp condition({:named, {:exact, :status_id}, key}, op, value, ctx) do
    with {:ok, values} <- exact_values(op, value, key) do
      {stable, others} = Enum.split_with(values, &stable?/1)
      matches = if others == [], do: [], else: [top_match(:status_id, others, ctx.fk)]
      empty = if stable == [], do: [], else: [%{is_empty: %{key: PayloadKeys.short(:status_id)}}]

      case empty ++ matches do
        [one] -> {:ok, one}
        both -> {:ok, %{should: both}}
      end
    end
  end

  defp condition({:named, {:exact, field}, key}, op, value, ctx) do
    with {:ok, values} <- exact_values(op, value, key),
         do: {:ok, top_match(field, values, ctx.fk)}
  end

  defp condition({:named, {kind, field}, key}, op, value, _ctx) when kind in [:date, :day] do
    with {:ok, range} <- date_range(op, value, key) do
      range = if kind == :day, do: Map.new(range, fn {o, t} -> {o, div_day(t)} end), else: range

      case field do
        f when f in [:fm_created, :fm_timestamp] -> {:ok, Qdrant.range_filter(f, range)}
        f -> {:ok, %{key: PayloadKeys.short(f), range: range}}
      end
    end
  end

  defp condition({:named, {:num, field}, key}, op, value, _ctx) do
    with {:ok, range} <- num_range(op, value, key),
         do: {:ok, %{key: PayloadKeys.short(field), range: range}}
  end

  # -- user-added keys ------------------------------------------------------

  defp condition({:user, key}, op, value, ctx) do
    case Map.fetch(ctx.ids, ctx.hmacs[key]) do
      {:ok, id} -> user_condition(id, op, value, ctx.fk, key)
      :error -> missing_key(ctx.user_id, key)
    end
  end

  defp missing_key(user_id, key) do
    if FrontmatterKeys.at_limit?(user_id),
      do: {:error, {:field_not_indexed, echo(key)}},
      else: {:error, {:unknown_field, echo(key)}}
  end

  defp user_condition(id, "in", values, fk, key) do
    if Enum.all?(values, &exact?/1) do
      {:ok, Qdrant.attr_filter(id, {:h, Enum.map(values, &value_id(fk, &1))})}
    else
      with {:ok, conds} <- collect(values, &user_condition(id, "eq", &1, fk, key)),
           do: {:ok, %{should: conds}}
    end
  end

  defp user_condition(id, "eq", value, fk, key) do
    cond do
      number?(value) -> {:ok, Qdrant.attr_filter(id, {:n, gte: value, lte: value})}
      date(value) -> with {:ok, r} <- date_range("eq", value, key), do: attr(id, :d, r)
      exact?(value) -> {:ok, Qdrant.attr_filter(id, {:h, value_id(fk, value)})}
      true -> invalid(key)
    end
  end

  defp user_condition(id, op, value, _fk, key) do
    cond do
      op in ~w(gt gte lt lte) and number?(value) ->
        attr(id, :n, %{@range_ops[op] => value})

      date(value) ->
        with {:ok, r} <- date_range(op, value, key), do: attr(id, :d, r)

      true ->
        invalid(key)
    end
  end

  defp attr(id, field, range), do: {:ok, Qdrant.attr_filter(id, {field, range})}

  # -- values ---------------------------------------------------------------

  defp exact_values("eq", value, key),
    do: if(exact?(value), do: {:ok, [value]}, else: invalid(key))

  defp exact_values("in", values, key),
    do: if(Enum.all?(values, &exact?/1), do: {:ok, values}, else: invalid(key))

  defp exact_values(_op, _value, key), do: invalid(key)

  defp top_match(field, values, fk) do
    ids = Enum.map(values, &value_id(fk, &1))
    match = if length(ids) == 1, do: %{value: hd(ids)}, else: %{any: ids}
    %{key: PayloadKeys.short(field), match: match}
  end

  defp num_range("eq", v, key),
    do: if(number?(v), do: {:ok, %{gte: v, lte: v}}, else: invalid(key))

  defp num_range(op, v, key) do
    if Map.has_key?(@range_ops, op) and number?(v),
      do: {:ok, %{@range_ops[op] => v}},
      else: invalid(key)
  end

  # Seconds bounds per the moduledoc's date rule.
  defp date_range(op, value, key) do
    case {date_kind(value), op} do
      {nil, _} -> invalid(key)
      {{:day, d}, "eq"} -> {:ok, %{gte: d, lt: d + @day}}
      {{:day, d}, o} when o in ~w(after gte) -> {:ok, %{gte: d}}
      {{:day, d}, o} when o in ~w(before lt) -> {:ok, %{lt: d}}
      {{:day, d}, "gt"} -> {:ok, %{gte: d + @day}}
      {{:day, d}, "lte"} -> {:ok, %{lt: d + @day}}
      {{:at, t}, "eq"} -> {:ok, %{gte: t, lte: t}}
      {{:at, t}, "after"} -> {:ok, %{gte: t}}
      {{:at, t}, "before"} -> {:ok, %{lt: t}}
      {{:at, t}, o} when is_map_key(@range_ops, o) -> {:ok, %{@range_ops[o] => t}}
      _ -> invalid(key)
    end
  end

  # Day numbers keep the operator: a midnight bound maps to its day exactly.
  defp div_day(t), do: Integer.floor_div(t, @day)

  defp date_kind(<<_::binary-size(10)>> = s), do: with({u, _} <- parse_date(s), do: {:day, u})
  defp date_kind(s), do: with({u, _} <- parse_date(s), do: {:at, u})

  defp date(v), do: date_kind(v) != nil

  defp parse_date(<<_y::binary-size(4), ?-, _m::binary-size(2), ?-, _rest::binary>> = s),
    do: FrontmatterDate.parse(s, :lenient)

  defp parse_date(_), do: nil

  # The same bound the indexing pass accepts (`FrontmatterAttrs.number/1`):
  # a bignum would only come back from Qdrant as a 400.
  defp number?(v), do: (is_integer(v) and abs(v) < 1.0e308) or is_float(v)

  defp exact?(v), do: (is_binary(v) and v != "" and not date(v)) or is_boolean(v)

  defp stable?(v), do: is_binary(v) and OkfFields.normalize_type(v) == "stable"

  defp value_id(fk, v), do: FilterId.attr_value(fk, to_string(v))

  defp type_b64(fk, v),
    do: Base.encode64(Crypto.hmac_field(fk, OkfFields.normalize_type(to_string(v))))

  defp invalid(key), do: {:error, {:invalid_field_filter, echo(key)}}

  defp echo(key), do: String.slice(key, 0, @max_echo)
end
