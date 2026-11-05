defmodule Engram.Search.FieldFilters do
  @moduledoc """
  Search filters on any frontmatter key (2026-10-20 rulings): each filter is
  `%{key, op, value}` with `op` one of `eq` (default), `in`, `gt`, `gte`,
  `lt`, `lte`, `after`, `before`. They match v5 points only (a v3/v4 point
  carries no `fa`); an unknown key is an explicit error, never an empty
  result.

  **Named fields** (and their aliases) route to the payload keys v5 already
  writes: `type`, `tags`, `status`, `author`, `reviewed_by`, `source` (alias
  `resource`, `sources`) and `project` match exactly; `created` (`date`),
  `updated` (`timestamp`, `modified`), `reviewed`, `expires`
  (`stale_after`), `due` and `priority` range. `status: stable` is the
  default and stored as no key, so it matches a missing `s`. `title`,
  `aliases`, `description`, `generated` and `verified` have no filter. A
  named key matches in any casing or width (NFKC + lower case) and under its
  localized names (`種類` is `type`, `Engram.Notes.KeyAliases`).

  **User-added keys** resolve to the per-user `key_id` through the dictionary
  (`FrontmatterKeys.lookup/2`), one query per request for every filter, and
  become nested `fa` conditions (key and value in the SAME entry). A key this
  user never wrote is `{:unknown_field, key}`; while the account is at its
  key limit it may have been skipped, so it is `{:field_not_indexed, key}`.

  Values: a string or boolean is an exact match; a number compares as a
  number (a quoted YAML number is a string and matches as one); an ISO date
  or datetime compares as a date, except on a named exact field, which holds
  every string as text. Date bounds: a bare date is the whole UTC
  day, so `eq` matches that day, `after`/`gte` start at it, `before`/`lt`
  end before it, `gt` starts the next day and `lte` ends with it; a
  datetime bound is that instant (`after` is `>=`, `before` is `<`).
  """

  alias Engram.Crypto
  alias Engram.Notes.FrontmatterDate
  alias Engram.Notes.FrontmatterKeys
  alias Engram.Notes.KeyAliases
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

  @doc "Longest key echoed back in an error message."
  def max_echo, do: @max_echo

  @typedoc """
  One parsed filter, independent of the store it runs on. `key_id` is the
  `note_attrs.key_id` (`FrontmatterKeys`: a reserved id for a named field, a
  dictionary id for a user-added key); `field` is the v5 payload field of a
  named key (nil for a user-added one). Exact values are the raw 32-byte
  HMACs `note_attrs.h` holds (a scalar for `eq`, a list for `in`); ranges are
  `%{gte | gt | lt | lte => value}`, dates in unix seconds.
  """
  @type spec ::
          {:h, atom() | nil, integer(), binary() | [binary()]}
          | {:status, boolean(), [binary()]}
          | {:range, atom() | nil, integer(), :n | :d, map()}
          | {:any, [spec()]}

  @doc """
  The Qdrant conditions for `filters`, or the first error. `filter_key` is
  the user's filter key (`Crypto.dek_filter_key/1`).
  """
  @spec to_conditions(Ecto.UUID.t(), binary(), [map()]) :: {:ok, [map()]} | {:error, error()}
  def to_conditions(user_id, filter_key, filters) do
    with {:ok, specs} <- to_specs(user_id, filter_key, filters),
         do: {:ok, Enum.map(specs, &qdrant(&1, filter_key))}
  end

  @doc """
  The parsed `filters` (`t:spec/0`), or the first error: the one parse both
  the Qdrant conditions (`to_conditions/3`) and the Postgres resolver
  (`Engram.Search.NoteFilter`) read.
  """
  @spec to_specs(Ecto.UUID.t(), binary(), [map()]) :: {:ok, [spec()]} | {:error, error()}
  def to_specs(_user_id, _filter_key, []), do: {:ok, []}

  def to_specs(_user_id, _filter_key, filters) when length(filters) > @max_filters,
    do: {:error, {:too_many_field_filters, @max_filters}}

  def to_specs(user_id, filter_key, filters) do
    with {:ok, parsed} <- collect(filters, &parse/1) do
      user_keys = for {{:user, key}, _op, _v} <- parsed, do: key
      hmacs = Map.new(user_keys, &{&1, FilterId.key_hmac(filter_key, &1)})
      ids = FrontmatterKeys.lookup(user_id, Map.values(hmacs))
      ctx = %{fk: filter_key, ids: ids, hmacs: hmacs, user_id: user_id}

      collect(parsed, fn {field, op, value} -> spec(field, op, value, ctx) end)
    end
  end

  @doc "The exact-match spec for notes tagged with any of `tags` (no prefix expansion)."
  @spec tags_spec(binary(), [String.t()]) :: {:h, :tags, non_neg_integer(), [binary()]}
  def tags_spec(filter_key, tags),
    do: {:h, :tags, named_id(:tags), Enum.map(tags, &Crypto.hmac_field(filter_key, &1))}

  @doc "The exact-match spec for notes whose OKF `type` is `type`."
  @spec type_spec(binary(), String.t()) :: {:h, :type, non_neg_integer(), binary()}
  def type_spec(filter_key, type), do: {:h, :type, named_id(:type), type_hmac(filter_key, type)}

  @doc "The range spec for `:created` or `:updated` (unix-second bounds)."
  @spec date_spec(:created | :updated, map()) ::
          {:range, :fm_created | :fm_timestamp, non_neg_integer(), :d, map()}
  def date_spec(:created, range), do: {:range, :fm_created, named_id(:created), :d, range}
  def date_spec(:updated, range), do: {:range, :fm_timestamp, named_id(:updated), :d, range}

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

  # NFKC + lower case, and a localized alias is its English field
  # (`KeyAliases`), the same fold the extraction side applies.
  defp field(key, op, value) do
    lower = KeyAliases.canonical(key) || OkfFields.normalize_type(key)

    cond do
      Map.has_key?(@named, lower) -> {:ok, {{:named, @named[lower], key}, op, value}}
      MapSet.member?(@unfilterable, lower) -> {:error, {:reserved_field, echo(key)}}
      true -> {:ok, {{:user, key}, op, value}}
    end
  end

  # -- named fields ---------------------------------------------------------

  defp spec({:named, :type, key}, op, value, ctx) do
    with {:ok, values} <- exact_values(op, value, key) do
      hmacs = Enum.map(values, &type_hmac(ctx.fk, &1))
      {:ok, {:h, :type, named_id(:type), if(op == "in", do: hmacs, else: hd(hmacs))}}
    end
  end

  defp spec({:named, :tags, key}, op, value, ctx) do
    with {:ok, values} <- exact_values(op, value, key),
         do: {:ok, tags_spec(ctx.fk, Enum.map(values, &to_string/1))}
  end

  defp spec({:named, {:exact, :status_id}, key}, op, value, ctx) do
    with {:ok, values} <- exact_values(op, value, key) do
      {stable, others} = Enum.split_with(values, &stable?/1)
      {:ok, {:status, stable != [], Enum.map(others, &value_hmac(ctx.fk, &1))}}
    end
  end

  defp spec({:named, {:exact, field}, key}, op, value, ctx) do
    with {:ok, values} <- exact_values(op, value, key) do
      hmacs = Enum.map(values, &value_hmac(ctx.fk, &1))
      {:ok, {:h, field, key_id(field), hmacs}}
    end
  end

  defp spec({:named, {:date, field}, key}, op, value, _ctx) do
    with {:ok, range} <- date_range(op, value, key),
         do: {:ok, {:range, field, key_id(field), :d, range}}
  end

  # A date-only field holds a day (its midnight): each bound is floored to
  # its day here, in the store-neutral spec, so Postgres (seconds) and
  # Qdrant (day numbers, `div_day/1`) compare the same days.
  defp spec({:named, {:day, field}, key}, op, value, _ctx) do
    with {:ok, range} <- date_range(op, value, key) do
      days = Map.new(range, fn {o, t} -> {o, div_day(t) * @day} end)
      {:ok, {:range, field, key_id(field), :d, days}}
    end
  end

  defp spec({:named, {:num, field}, key}, op, value, _ctx) do
    with {:ok, range} <- num_range(op, value, key),
         do: {:ok, {:range, field, key_id(field), :n, range}}
  end

  # -- user-added keys ------------------------------------------------------

  defp spec({:user, key}, op, value, ctx) do
    case Map.fetch(ctx.ids, ctx.hmacs[key]) do
      {:ok, id} -> user_spec(id, op, value, ctx.fk, key)
      :error -> missing_key(ctx.user_id, key)
    end
  end

  defp missing_key(user_id, key) do
    if FrontmatterKeys.at_limit?(user_id),
      do: {:error, {:field_not_indexed, echo(key)}},
      else: {:error, {:unknown_field, echo(key)}}
  end

  defp user_spec(id, "in", values, fk, key) do
    if Enum.all?(values, &exact?/1) do
      {:ok, {:h, nil, id, Enum.map(values, &value_hmac(fk, &1))}}
    else
      with {:ok, specs} <- collect(values, &user_spec(id, "eq", &1, fk, key)),
           do: {:ok, {:any, specs}}
    end
  end

  defp user_spec(id, "eq", value, fk, key) do
    cond do
      number?(value) -> {:ok, {:range, nil, id, :n, %{gte: value, lte: value}}}
      date(value) -> with {:ok, r} <- date_range("eq", value, key), do: user_range(id, :d, r)
      exact?(value) -> {:ok, {:h, nil, id, value_hmac(fk, value)}}
      true -> invalid(key)
    end
  end

  defp user_spec(id, op, value, _fk, key) do
    cond do
      op in ~w(gt gte lt lte) and number?(value) ->
        user_range(id, :n, %{@range_ops[op] => value})

      date(value) ->
        with {:ok, r} <- date_range(op, value, key), do: user_range(id, :d, r)

      true ->
        invalid(key)
    end
  end

  defp user_range(id, col, range), do: {:ok, {:range, nil, id, col, range}}

  # -- Qdrant conditions ----------------------------------------------------

  defp qdrant({:h, :type, _id, v}, _fk), do: Qdrant.match_filter(:type, b64(v))
  defp qdrant({:h, :tags, _id, v}, _fk), do: Qdrant.match_filter(:tags, b64(v))
  defp qdrant({:h, nil, id, v}, _fk), do: Qdrant.attr_filter(id, {:h, filter_id(v)})

  defp qdrant({:h, field, _id, hmacs}, _fk) do
    ids = filter_id(hmacs)
    match = if length(ids) == 1, do: %{value: hd(ids)}, else: %{any: ids}
    %{key: PayloadKeys.short(field), match: match}
  end

  defp qdrant({:status, stable?, hmacs}, fk) do
    matches = if hmacs == [], do: [], else: [qdrant({:h, :status_id, nil, hmacs}, fk)]
    empty = if stable?, do: [%{is_empty: %{key: PayloadKeys.short(:status_id)}}], else: []

    case empty ++ matches do
      [one] -> one
      both -> %{should: both}
    end
  end

  defp qdrant({:range, f, _id, :d, range}, _fk) when f in [:fm_created, :fm_timestamp],
    do: Qdrant.range_filter(f, range)

  # Date-only payload fields hold day numbers; the operator is kept, so a
  # midnight bound maps to its day exactly.
  defp qdrant({:range, f, _id, :d, range}, _fk) when f in [:fm_expires, :fm_due],
    do: %{key: PayloadKeys.short(f), range: Map.new(range, fn {o, t} -> {o, div_day(t)} end)}

  defp qdrant({:range, nil, id, col, range}, _fk), do: Qdrant.attr_filter(id, {col, range})
  defp qdrant({:range, f, _id, _col, range}, _fk), do: %{key: PayloadKeys.short(f), range: range}
  defp qdrant({:any, specs}, fk), do: %{should: Enum.map(specs, &qdrant(&1, fk))}

  defp b64(v) when is_list(v), do: Enum.map(v, &Base.encode64/1)
  defp b64(v), do: Base.encode64(v)

  defp filter_id(v) when is_list(v), do: Enum.map(v, &FilterId.from_hmac/1)
  defp filter_id(v), do: FilterId.from_hmac(v)

  # The `note_attrs.key_id` of a named payload field.
  @key_names %{
    status_id: :status,
    author_id: :author,
    rev_by_id: :reviewed_by,
    proj_id: :project,
    src_id: :source,
    fm_created: :created,
    fm_timestamp: :updated,
    fm_reviewed: :reviewed,
    fm_expires: :expires,
    fm_due: :due,
    fm_priority: :priority
  }

  defp key_id(field), do: named_id(Map.fetch!(@key_names, field))
  defp named_id(name), do: FrontmatterKeys.named_id(name)

  # -- values ---------------------------------------------------------------

  # Named exact fields hold every string as text, date-shaped ones included
  # (`project: 2026-01-01`), so no string is read as a date here.
  defp exact_values("eq", value, key),
    do: if(text?(value), do: {:ok, [value]}, else: invalid(key))

  defp exact_values("in", values, key),
    do: if(Enum.all?(values, &text?/1), do: {:ok, values}, else: invalid(key))

  defp exact_values(_op, _value, key), do: invalid(key)

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

  # A number too: the field holds `status: 2` as the text "2".
  defp text?(v), do: (is_binary(v) and v != "") or is_boolean(v) or is_number(v)

  defp stable?(v), do: is_binary(v) and OkfFields.normalize_type(v) == "stable"

  defp value_hmac(fk, v), do: FilterId.value_hmac(fk, to_string(v))

  defp type_hmac(fk, v), do: Crypto.hmac_field(fk, OkfFields.normalize_type(to_string(v)))

  defp invalid(key), do: {:error, {:invalid_field_filter, echo(key)}}

  defp echo(key), do: String.slice(key, 0, @max_echo)
end
