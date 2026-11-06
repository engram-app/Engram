defmodule Engram.Search.NoteFilter do
  @moduledoc """
  Postgres answers every note filter (R10.2 / R10.3, design
  `2026-11-05-immutable-chunk-index-design`): a vector point carries only
  `u`, `v`, `n`, so tags, folder, dates and frontmatter fields resolve here,
  to note ids, and Qdrant gets an id list.

  A filter is a map; its keys AND together:

    * `:folder`: a folder path; the folder and its whole subtree
      (`Folders.Rows.subtree_refs/3`). `""` is the vault root, so no filter.
    * `:tags`: any of these tags, a nested tag included (`a/b` matches
      `a/b/c`), expanded against the vault's tag list at query time.
    * `:type`: the OKF `type` (case and width folded).
    * `:fields`: `Engram.Search.FieldFilters` filters (`%{key, op, value}`),
      the same parse the Qdrant conditions use.
    * `:created_after` / `:created_before` / `:updated_after` /
      `:updated_before`: `DateTime` bounds, inclusive, on the effective date
      (`Engram.Notes.EffectiveDates`: frontmatter, else file time, else row
      time, as the v5 payload's `cr` / `up`).
    * `:and` / `:or`: a list of filters; `:not`: one filter.

  Only live notes (`kind = 'note'`, not trashed) of `user` in `vault`, inside
  the tenant transaction. Type, folder and the created / updated dates come
  from the note row (written with the note); tags and the other frontmatter
  values from `note_attrs`, which the index pass writes, so they are as fresh
  as the vector index.
  """
  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Folders.Rows
  alias Engram.Notes
  alias Engram.Notes.EffectiveDates
  alias Engram.Notes.Keys
  alias Engram.Notes.NoteAttr
  alias Engram.Pager
  alias Engram.Repo
  alias Engram.Search.FieldFilters
  alias Engram.Vector.Qdrant

  require EffectiveDates

  # The date keys are `Engram.Search.date_params/0`'s.
  @keys ~w(and or not folder tags type fields created_after created_before updated_after updated_before)a

  # Inclusive bounds for an integer-seconds date with no bound on one side.
  @min_s -9_223_372_036_854_775_808
  @max_s 9_223_372_036_854_775_807

  # Filter-only pages: at most this many matches page over their ids.
  @page_ids 1_000

  @type filter :: map() | keyword()
  @type resolved :: {:ids, [Ecto.UUID.t()]} | {:exclude, [Ecto.UUID.t()]} | :too_wide

  @doc """
  The notes `filter` matches, in the cheapest form for Qdrant:

    * `{:ids, ids}` when at most `Qdrant.max_note_ids/0` notes match
      (`[]` = none), the most one Qdrant filter carries on `n`,
    * `{:exclude, ids}` when at most that many live notes do NOT match
      (`[]` = every note matches),
    * `:too_wide` otherwise: search the vault and post-filter.

  `vault` may be a list (cross-vault search): each vault resolves on its
  own, the cap applies to the UNION of the matches, and the answer is
  `{:ids, _}` or `:too_wide` (no complement across vaults).

  Options: `:within` (a list of note ids) returns `{:ids, subset}`, the ids in
  it the filter matches (a post-filter for an oversampled candidate set; no
  cap); `:cap` overrides `Qdrant.max_note_ids/0` (tests). Ids are in no particular order.
  """
  @spec resolve(map(), map() | [map()], filter(), keyword()) ::
          {:ok, resolved()} | {:error, FieldFilters.error()}
  def resolve(user, vault, filter, opts \\ [])

  def resolve(user, vaults, filter, opts) when is_list(vaults) do
    cap = Keyword.get_lazy(opts, :cap, &Qdrant.max_note_ids/0)

    Enum.reduce_while(vaults, {:ok, {:ids, []}}, fn vault, {:ok, {:ids, acc}} ->
      # Each vault is capped at what the union has left, so a wide one stops early.
      left = if opts[:within], do: cap, else: cap - length(acc)

      case resolve(user, vault, filter, Keyword.put(opts, :cap, max(left, 0))) do
        {:ok, {:ids, ids}} -> {:cont, {:ok, {:ids, acc ++ ids}}}
        {:ok, _wide_or_exclude} -> {:halt, {:ok, :too_wide}}
        error -> {:halt, error}
      end
    end)
  end

  def resolve(user, vault, filter, opts) do
    cap = Keyword.get_lazy(opts, :cap, &Qdrant.max_note_ids/0)
    within = opts[:within]

    # The folder walk and the tag list read RLS tables too: all of it runs
    # inside the tenant transaction.
    {:ok, out} =
      Repo.with_tenant(user.id, fn ->
        with {:ok, cond} <- compile(user, vault, filter) do
          base = live_ids(user, vault)

          if within,
            do: {:ok, {:ids, within(base, cond, within)}},
            else: {:ok, capped(base, cond, cap)}
        end
      end)

    out
  end

  @doc """
  `{matched, live}`: how many live notes `filter` matches, and how many live
  notes there are, in one pass over the vault's live notes. A `:too_wide`
  search sizes its oversample by `matched / live`. `vault` may be a list:
  the counts sum.
  """
  @spec count(map(), map() | [map()], filter()) ::
          {:ok, {non_neg_integer(), non_neg_integer()}} | {:error, FieldFilters.error()}
  def count(user, vaults, filter) when is_list(vaults) do
    Enum.reduce_while(vaults, {:ok, {0, 0}}, fn vault, {:ok, {matched, live}} ->
      case count(user, vault, filter) do
        {:ok, {m, l}} -> {:cont, {:ok, {matched + m, live + l}}}
        error -> {:halt, error}
      end
    end)
  end

  # ponytail: an exact count reads every live note of the vault; only a
  # `:too_wide` filter (over `max_note_ids/0` matches AND non-matches) pays
  # it. Sample a bounded prefix if a vault that size makes it slow.
  def count(user, vault, filter) do
    {:ok, out} =
      Repo.with_tenant(user.id, fn ->
        with {:ok, cond} <- compile(user, vault, filter) do
          counts = %{
            matched: dynamic([n], filter(count(n.id), ^cond)),
            live: dynamic([n], count(n.id))
          }

          %{matched: m, live: l} = Repo.one(from(n in live(user, vault), select: ^counts))
          {:ok, {m, l}}
        end
      end)

    out
  end

  # The live notes (`kind = 'note'`, not trashed) of `user` in `vault`.
  defp live(user, vault), do: from(n in Notes.scoped_live(user, vault), where: n.kind == "note")
  defp live_ids(user, vault), do: from(n in live(user, vault), select: n.id)

  defp within(_base, _cond, []), do: []

  defp within(base, cond, ids),
    do: Repo.all(from(n in base, where: n.id in type(^ids, {:array, Ecto.UUID}), where: ^cond))

  defp capped(base, cond, cap) do
    case ids(base, cond, cap) do
      ids when length(ids) <= cap ->
        {:ids, ids}

      _ ->
        case ids(base, dynamic(not (^cond)), cap) do
          ids when length(ids) <= cap -> {:exclude, ids}
          _ -> :too_wide
        end
    end
  end

  defp ids(base, cond, cap), do: Repo.all(from(n in base, where: ^cond, limit: ^(cap + 1)))

  @doc """
  Filter-only search (no query vector): one page of the live notes `filter`
  matches, newest `updated_at` first, metadata only. Options: `:limit`
  (`Pager.limit/1`), `:cursor` (the previous page's `next_cursor`), `:page_ids`
  (tests: how many matches page over their ids, default 1,000).
  """
  @spec page(map(), map(), filter(), keyword()) ::
          {:ok, %{notes: [Engram.Notes.Note.t()], next_cursor: String.t() | nil}}
          | {:error, FieldFilters.error() | :invalid_cursor}
  def page(user, vault, filter, opts \\ []) do
    limit = Pager.limit(opts[:limit])
    scope = Pager.scope(:note_filter, user, vault)

    with {:ok, before} <- Pager.decode(scope, opts[:cursor]),
         {:ok, cond} <- narrow(user, vault, filter, Keyword.get(opts, :page_ids, @page_ids)) do
      before = with {us, id} <- before, do: {DateTime.from_unix!(us, :microsecond), id}

      {:ok, rows} =
        Notes.list_recent_notes(user, vault, limit + 1, where: cond, before: before)

      # Microseconds, not the DateTime: its term overflows Pager's 512-byte cap.
      {notes, next} =
        Pager.paginate(
          rows,
          limit,
          scope,
          &{DateTime.to_unix(&1.updated_at, :microsecond), &1.id}
        )

      {:ok, %{notes: notes, next_cursor: next}}
    end
  end

  @doc "Whether `filter` names any filter at all (an empty one matches every note)."
  @spec any?(filter()) :: boolean()
  def any?(filter), do: filter |> take() |> Enum.any?(fn {_k, v} -> v not in [nil, [], ""] end)

  # -- compile: filter -> one non-NULL boolean over `notes` (binding n) ----

  # The newest-first walk evaluates the filter row by row, so a rare match
  # (a leaf folder, a narrow date) walked the whole vault. Up to `page_ids`
  # matches page over their ids instead (one index-only lookup, then that
  # many rows sorted); past it the matches are dense enough that the walk
  # finds a page within about `limit * notes / page_ids` rows.
  defp narrow(user, vault, filter, page_ids) do
    {:ok, out} =
      Repo.with_tenant(user.id, fn ->
        with {:ok, cond} <- compile(user, vault, filter) do
          base = live_ids(user, vault)

          case ids(base, cond, page_ids) do
            ids when length(ids) <= page_ids ->
              {:ok, dynamic([n], n.id in type(^ids, {:array, Ecto.UUID}))}

            _ ->
              {:ok, cond}
          end
        end
      end)

    out
  end

  defp compile(user, vault, filter) do
    case Crypto.dek_filter_key(user) do
      {:ok, fk} -> node(filter, %{fk: fk, user: user, vault: vault})
      # No DEK, no encrypted notes: nothing can match.
      {:error, _} -> {:ok, dynamic(false)}
    end
  end

  defp take(filter) when is_list(filter), do: filter |> Map.new() |> take()
  # `tags: [""]` (REST `tags[]=`) names no tag, as in `Search`: no filter.
  defp take(filter) when is_map(filter) do
    filter
    |> Map.take(@keys)
    |> Map.update(:tags, nil, &(&1 |> List.wrap() |> Enum.reject(fn t -> t in [nil, ""] end)))
  end

  defp node(filter, ctx) do
    filter
    |> take()
    |> Enum.reject(fn {k, v} -> k not in [:and, :or] and v in [nil, [], ""] end)
    |> merge_dates()
    |> all(fn {k, v} -> leaf(k, v, ctx) end, &dynamic(^&1 and ^&2), dynamic(true))
  end

  @date_bounds %{
    created_after: {:created, :gte},
    created_before: {:created, :lte},
    updated_after: {:updated, :gte},
    updated_before: {:updated, :lte}
  }

  # `updated_after` + `updated_before` are ONE range: one pair of `note_attrs`
  # semi-joins, not two.
  defp merge_dates(pairs) do
    {dates, rest} = Enum.split_with(pairs, fn {k, _v} -> Map.has_key?(@date_bounds, k) end)

    ranges =
      Enum.reduce(dates, %{}, fn {k, %DateTime{} = at}, acc ->
        {kind, bound} = @date_bounds[k]

        Map.update(
          acc,
          {:date, kind},
          %{bound => DateTime.to_unix(at)},
          &Map.put(&1, bound, DateTime.to_unix(at))
        )
      end)

    rest ++ Enum.to_list(ranges)
  end

  # Folds `fun` over `items` with `join`, halting on the first error.
  defp all(items, fun, join, empty) do
    Enum.reduce_while(items, {:ok, nil}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, d} -> {:cont, {:ok, if(acc, do: join.(acc, d), else: d)}}
        error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, nil} -> {:ok, empty}
      other -> other
    end)
  end

  defp leaf(:and, filters, ctx),
    do: all(filters, &node(&1, ctx), &dynamic(^&1 and ^&2), dynamic(true))

  defp leaf(:or, filters, ctx),
    do: all(filters, &node(&1, ctx), &dynamic(^&1 or ^&2), dynamic(false))

  defp leaf(:not, filter, ctx),
    do: with({:ok, d} <- node(filter, ctx), do: {:ok, dynamic(not (^d))})

  defp leaf(:folder, folder, ctx), do: {:ok, folder(String.trim(folder, "/"), ctx)}

  defp leaf(:tags, tags, ctx),
    do: {:ok, spec(FieldFilters.tags_spec(ctx.fk, expand(tags, ctx)), ctx)}

  defp leaf(:type, type, ctx), do: {:ok, spec(FieldFilters.type_spec(ctx.fk, type), ctx)}

  defp leaf(:fields, fields, ctx) do
    with {:ok, specs} <- FieldFilters.to_specs(to_string(ctx.user.id), ctx.fk, fields),
         do: all(specs, &{:ok, spec(&1, ctx)}, &dynamic(^&1 and ^&2), dynamic(true))
  end

  defp leaf({:date, kind}, range, ctx), do: {:ok, spec(FieldFilters.date_spec(kind, range), ctx)}

  defp folder("", _ctx), do: dynamic(true)

  defp folder(path, ctx) do
    refs = for %{full_path_hmac: h} <- Rows.subtree_refs(ctx.user, ctx.vault.id, [path]), do: h

    # The root's own path key too: a note in a folder with no `folders` row
    # yet (one the previous release wrote, before `DataMigrations.FolderTable`
    # heals it) still carries that key, as vector search's exact
    # `folder_hmac` match finds it.
    hmacs = Enum.uniq([Rows.path_hmac(ctx.fk, path) | Enum.filter(refs, &is_binary/1)])

    # `folder_id = ANY(...)` on `notes_folder (vault_id, folder_id)`: every
    # note carries its folder's key (a trigger writes it). `IS NOT NULL`
    # keeps a root note's NULL false (exact under `not`) without hiding the
    # column from the index, as a `coalesce()` around it did. One `ids?()`
    # read for the column and its values, so they agree.
    ids? = Keys.ids?()
    col = Keys.col(:folder, ids?)
    match = Keys.in_any(:folder, hmacs, ids?)
    dynamic([n], not is_nil(field(n, ^col)) and ^match)
  end

  # Nested tags: `a/b` is `a/b` and every `a/b/...` the vault uses. Case
  # folded, as Obsidian matches tags (`Project` is `project/x`'s parent);
  # the expansion is the vault's own spellings, which the HMACs match.
  defp expand(tags, ctx) do
    wanted = Enum.map(tags, &String.trim_leading(to_string(&1), "#"))
    folded = Enum.map(wanted, &String.downcase/1)
    {:ok, known} = Notes.list_tags(ctx.user, ctx.vault)

    nested =
      for t <- known,
          lt = String.downcase(t),
          Enum.any?(folded, &(lt == &1 or String.starts_with?(lt, &1 <> "/"))),
          do: t

    Enum.uniq(wanted ++ nested)
  end

  # -- specs -> SQL -----------------------------------------------------------

  # Type is on the note row, behind the `(vault_id, type_id)` index. Tags go
  # through `note_attrs` like every other key: staging EXPLAIN 2026-11-05,
  # `notes.tags_hmac && $n` read the heap of every live note in the vault
  # (~7 ms per 1k notes); the `note_attrs` index reads only the matches.
  defp spec({:h, :type, _key_id, v}, _ctx) do
    match = Keys.in_any(:type, List.wrap(v))
    dynamic([n], fragment("coalesce(?, false)", ^match))
  end

  defp spec({:h, _field, key_id, v}, ctx), do: in_attrs(ctx, key_id, h_in(List.wrap(v)))

  defp spec({:status, stable?, hmacs}, ctx) do
    status = Engram.Notes.FrontmatterKeys.named_id(:status)
    has = if hmacs == [], do: dynamic(false), else: in_attrs(ctx, status, h_in(hmacs))
    # `h IS NOT NULL` lets the partial `(vault_id, key_id, h)` index answer it.
    any_status = in_attrs(ctx, status, dynamic([a], not is_nil(a.h)))
    if stable?, do: dynamic(^has or not (^any_status)), else: has
  end

  # `created` / `updated` (named keys and the `*_after` / `*_before` opts):
  # one range on the `notes_eff_*_live` expression index. The effective
  # date falls back from the frontmatter to the file and row times, as the
  # payload's `cr` / `up` do; `EffectiveDates.updated_sql/1` /
  # `created_sql/1` are the indexed expressions, verbatim.
  defp spec({:range, field, _key_id, :d, range}, _ctx)
       when field in [:fm_created, :fm_timestamp] do
    {lo, hi} = bounds(range)
    eff_range(field, lo, hi)
  end

  defp spec({:range, _field, key_id, :d, range}, ctx) do
    {lo, hi} = bounds(range)
    in_attrs(ctx, key_id, dynamic([a], a.d >= ^lo and a.d <= ^hi))
  end

  defp spec({:range, _field, key_id, :n, range}, ctx),
    do: in_attrs(ctx, key_id, Enum.reduce(range, dynamic(true), &num/2))

  defp spec({:any, specs}, ctx),
    do: Enum.reduce(specs, dynamic(false), &dynamic(^&2 or ^spec(&1, ctx)))

  defp eff_range(:fm_timestamp, lo, hi),
    do:
      dynamic([n], EffectiveDates.updated_sql(n) >= ^lo and EffectiveDates.updated_sql(n) <= ^hi)

  defp eff_range(:fm_created, lo, hi),
    do:
      dynamic([n], EffectiveDates.created_sql(n) >= ^lo and EffectiveDates.created_sql(n) <= ^hi)

  defp h_in(hmacs), do: dynamic([a], a.h in ^hmacs)

  defp num({:gte, v}, d), do: dynamic([a], ^d and a.n >= ^v)
  defp num({:gt, v}, d), do: dynamic([a], ^d and a.n > ^v)
  defp num({:lte, v}, d), do: dynamic([a], ^d and a.n <= ^v)
  defp num({:lt, v}, d), do: dynamic([a], ^d and a.n < ^v)

  # Dates are whole seconds, so every bound is an inclusive integer.
  defp bounds(range) do
    Enum.reduce(range, {@min_s, @max_s}, fn
      {:gte, v}, {lo, hi} -> {max(lo, v), hi}
      {:gt, v}, {lo, hi} -> {max(lo, v + 1), hi}
      {:lte, v}, {lo, hi} -> {lo, min(hi, v)}
      {:lt, v}, {lo, hi} -> {lo, min(hi, v - 1)}
    end)
  end

  # `n.id IN (note_attrs rows of key_id matching cond)`: the
  # `(vault_id, key_id, h | n | d) INCLUDE (note_id, user_id)` indexes. Never
  # NULL (note_id is NOT NULL), so `not` is exact.
  #
  # Wrapped in `coalesce(..., false)` (a no-op: the IN is never NULL) so
  # Postgres cannot pull the subquery up into a join: a sublink inside a
  # function argument always stays a hashed SubPlan. The matching note ids
  # are read once (index-only) and the vault's live notes are probed
  # against them through a covering live index (`notes_recent_index`,
  # index-only). Pulled up, the planner costed the attr side from
  # `h = ANY($n)`'s default estimate and chose a nested loop over
  # `notes_pkey`, one heap page per match: staging 2026-11-05, 15 to 24 us
  # per match, 150 to 250 ms at the 10,240-id cap on a 40k-note vault. The
  # hashed form costs about 0.5 us per live note plus 0.7 us per attr row,
  # whatever the estimate. (`OFFSET 0` does not stop the pull-up.)
  defp in_attrs(ctx, key_id, cond) do
    rows =
      from(a in NoteAttr,
        where: a.vault_id == ^ctx.vault.id and a.key_id == ^key_id,
        where: ^cond,
        select: a.note_id
      )

    dynamic([n], fragment("coalesce(?, false)", n.id in subquery(rows)))
  end
end
