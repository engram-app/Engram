defmodule Engram.Notes.FieldCatalog do
  @moduledoc """
  Every frontmatter field a vault uses, so search can ask "what fields do I
  have to work with?" (MCP `list_fields`, `GET /api/fields`). Each field
  gives its name (the key a `search_notes` `fields` filter takes), its value
  kinds, how many live notes carry it, whether a note holds a list of values,
  the number/date range, and the 50 most used exact values with counts.

  Derived on read from `note_attrs` (written by the v5 indexing pass) and the
  per-user `frontmatter_keys` dictionary; nothing is counted on write. Two
  queries, each an index-only scan of the partial `(vault_id, key_id, h|n|d)`
  indexes (they INCLUDE `note_id` and the RLS column `user_id`). Names are
  decrypted from the dictionary (user-added keys) or come from the reserved
  map (named fields). A string value is stored only as an HMAC, so its text
  comes from one sample note's frontmatter, decrypted; a value that note no
  longer holds (edited since the pass) is left out.

  Cached per vault on `vaults.change_seq` (`:field_catalog`): a note write
  moves the seq, so a stale entry is never read; the index pass, which writes
  `note_attrs` without moving the seq, evicts the vault (`evict/1`).

  Reads run under the caller's tenant, and decryption uses only the caller's
  DEK. Names and values are never logged.
  """

  import Ecto.Query

  alias Engram.Cache
  alias Engram.Crypto
  alias Engram.Logger.DecryptFailure
  alias Engram.Notes
  alias Engram.Notes.Frontmatter
  alias Engram.Notes.FrontmatterKey
  alias Engram.Notes.FrontmatterKeys
  alias Engram.Notes.OkfFields
  alias Engram.Repo
  alias Engram.Vector.FilterId

  @top_values 50
  @day 86_400

  @type field :: %{
          name: String.t(),
          kinds: [String.t()],
          list: boolean(),
          note_count: non_neg_integer(),
          number_range: %{min: float(), max: float()} | nil,
          date_range: %{min: String.t(), max: String.t()} | nil,
          values: [%{value: String.t(), count: pos_integer()}]
        }

  # One row per key: kinds present, live notes, rows (more rows than notes =
  # some note holds a list), and the n/d ranges. Each branch reads one
  # partial index.
  @stats_sql """
  SELECT a.key_id, bool_or(a.kind = 'h'), bool_or(a.kind = 'n'), bool_or(a.kind = 'd'),
         count(DISTINCT a.note_id), count(*), min(a.n), max(a.n), min(a.d), max(a.d)
  FROM (
    SELECT key_id, note_id, 'h' AS kind, NULL::float8 AS n, NULL::bigint AS d
      FROM note_attrs WHERE vault_id = $1 AND h IS NOT NULL
    UNION ALL
    SELECT key_id, note_id, 'n', n, NULL FROM note_attrs WHERE vault_id = $1 AND n IS NOT NULL
    UNION ALL
    SELECT key_id, note_id, 'd', NULL, d FROM note_attrs WHERE vault_id = $1 AND d IS NOT NULL
  ) a
  WHERE NOT EXISTS (
    SELECT 1 FROM notes t WHERE t.id = a.note_id AND t.deleted_at IS NOT NULL
  )
  GROUP BY a.key_id
  """

  # The most used exact values per key, with one sample note each to read the
  # value's text from.
  @values_sql """
  SELECT key_id, h, notes, sample FROM (
    SELECT a.key_id, a.h, count(DISTINCT a.note_id) AS notes, any_value(a.note_id) AS sample,
           row_number() OVER (PARTITION BY a.key_id ORDER BY count(DISTINCT a.note_id) DESC, a.h) AS rn
    FROM note_attrs a
    WHERE a.vault_id = $1 AND a.h IS NOT NULL
      AND NOT EXISTS (
        SELECT 1 FROM notes t WHERE t.id = a.note_id AND t.deleted_at IS NOT NULL
      )
    GROUP BY a.key_id, a.h
  ) v
  WHERE rn <= #{@top_values}
  """

  @named_names Map.new(FrontmatterKeys.named(), fn {name, id} -> {id, Atom.to_string(name)} end)

  @doc "The fields of `vault`, most used first. `{:ok, []}` for a user without a DEK."
  @spec list(map(), map()) :: {:ok, [field()]}
  def list(user, vault) do
    with {:ok, fk} <- Crypto.dek_filter_key(user),
         {:ok, dek} <- Crypto.get_dek(user),
         seq when is_integer(seq) <- current_seq(user, vault) do
      {:ok,
       Cache.fetch(:field_catalog, {vault.id, {user.id, seq}}, fn ->
         build(user, vault, fk, dek)
       end)}
    else
      _no_dek_or_vault -> {:ok, []}
    end
  end

  @doc "Drop every cached catalog of `vault_id` (after an index pass commits), cluster-wide."
  @spec evict(Ecto.UUID.t()) :: :ok
  def evict(vault_id), do: Cache.evict(:field_catalog, vault_id)

  @doc false
  # The catalog's SQL and params, for the query-plan tests.
  @spec explain_queries(Ecto.UUID.t()) :: [{String.t(), list()}]
  def explain_queries(vault_id) do
    params = [Ecto.UUID.dump!(vault_id)]
    [{@stats_sql, params}, {@values_sql, params}]
  end

  # nil when the vault is not this user's (RLS hides its row).
  defp current_seq(user, vault) do
    Repo.with_tenant!(user.id, fn ->
      case Repo.query!("SELECT change_seq FROM vaults WHERE id = $1", [
             Ecto.UUID.dump!(vault.id)
           ]) do
        %{rows: [[seq]]} -> seq
        %{rows: []} -> nil
      end
    end)
  end

  defp build(user, vault, fk, dek) do
    {stats, values, keys} =
      Repo.with_tenant!(user.id, fn ->
        [{stats_sql, params}, {values_sql, _}] = explain_queries(vault.id)
        stats = Repo.query!(stats_sql, params).rows
        values = Repo.query!(values_sql, params).rows
        user_ids = for [id | _] <- stats, id >= FrontmatterKeys.first_user_id(), do: id

        keys =
          Repo.all(
            from(k in FrontmatterKey, where: k.user_id == ^user.id and k.key_id in ^user_ids)
          )

        {stats, values, keys}
      end)

    names = Map.merge(@named_names, user_key_names(keys, dek, user))
    texts = value_texts(user, vault, values, fk)

    values_by_key =
      values
      |> Enum.group_by(&hd/1)
      |> Map.new(fn {key_id, rows} ->
        {key_id,
         for([_k, h, count, _s] <- rows, text = texts[h], do: %{value: text, count: count})
         |> Enum.sort_by(&{-&1.count, &1.value})}
      end)

    stats
    |> Enum.flat_map(fn [key_id | _] = row ->
      case names do
        %{^key_id => name} -> [field(name, row, Map.get(values_by_key, key_id, []))]
        _ -> []
      end
    end)
    |> Enum.sort_by(&{-&1.note_count, &1.name})
  end

  defp field(name, [_id, h?, n?, d?, notes, rows, n_min, n_max, d_min, d_max], values) do
    %{
      name: name,
      kinds: kinds(h?, n?, d?, values),
      list: rows > notes,
      note_count: notes,
      number_range: if(n?, do: %{min: n_min, max: n_max}),
      date_range: if(d?, do: %{min: date(d_min), max: date(d_max)}),
      values: values
    }
  end

  defp kinds(h?, n?, d?, values) do
    exact = if boolean?(values), do: "boolean", else: "string"
    for {true, kind} <- [{h?, exact}, {n?, "number"}, {d?, "date"}], do: kind
  end

  defp boolean?([]), do: false
  defp boolean?(values), do: Enum.all?(values, &(String.downcase(&1.value) in ~w(true false)))

  # A date-only value is stored as that day's midnight UTC.
  defp date(unix) when rem(unix, @day) == 0,
    do: unix |> DateTime.from_unix!() |> DateTime.to_date() |> Date.to_iso8601()

  defp date(unix), do: unix |> DateTime.from_unix!() |> DateTime.to_iso8601()

  defp user_key_names(keys, dek, user) do
    for key <- keys, reduce: %{} do
      acc ->
        case FrontmatterKeys.name(key, dek) do
          {:ok, name} ->
            Map.put(acc, key.key_id, name)

          :error ->
            DecryptFailure.log("field_catalog_key_decrypt_failed", :decrypt_failed,
              user_id: user.id
            )

            acc
        end
    end
  end

  # value HMAC => text, from each sample note's frontmatter (and, for `type`
  # and `tags`, the note row's own blind-index inputs).
  # ponytail: one decrypt per distinct sample note, so a vault with many keys
  # of many distinct values pays up to 50 x keys decrypts on a cache miss.
  # Pick samples that overlap (e.g. min(note_id) once uuid has min/max) if a
  # cold catalog shows up in traces.
  defp value_texts(_user, _vault, [], _fk), do: %{}

  defp value_texts(user, vault, values, fk) do
    ids = values |> Enum.map(&List.last/1) |> Enum.uniq() |> Enum.map(&Ecto.UUID.load!/1)

    query = from(n in Notes.scoped_live(user, vault), where: n.id in ^ids)
    notes = Repo.with_tenant!(user.id, fn -> Repo.all(query) end)

    notes
    |> Crypto.decrypt_notes_batch(user)
    |> Enum.zip(notes)
    |> Enum.reduce(%{}, fn
      {{:ok, note}, _row}, acc ->
        Map.merge(acc, note_texts(note, fk))

      {{:error, reason}, row}, acc ->
        DecryptFailure.log("field_catalog_decrypt_failed", reason,
          user_id: user.id,
          note_id: row.id
        )

        acc
    end)
  end

  defp note_texts(note, fk) do
    frontmatter =
      case note.content && Frontmatter.split(note.content) do
        {block, _body} when is_binary(block) ->
          for s <- leaves(OkfFields.values(Frontmatter.parse(block))),
              into: %{},
              do: {FilterId.value_hmac(fk, s), s}

        _ ->
          %{}
      end

    tags = Map.new(note.tags || [], &{Crypto.hmac_field(fk, &1), &1})

    type =
      if note.type,
        do: %{Crypto.hmac_field(fk, OkfFields.normalize_type(note.type)) => note.type},
        else: %{}

    frontmatter |> Map.merge(tags) |> Map.merge(type)
  end

  # Every string-like leaf, nested aliases (`generated.by`, `verified[].by`)
  # included: the HMAC lookup picks the ones that are values.
  defp leaves(map) when is_map(map), do: map |> Map.values() |> Enum.flat_map(&leaves/1)
  defp leaves(list) when is_list(list), do: Enum.flat_map(list, &leaves/1)
  defp leaves(s) when is_binary(s) and s != "", do: [s]
  defp leaves(b) when is_boolean(b), do: [to_string(b)]
  defp leaves(i) when is_integer(i), do: [Integer.to_string(i)]
  defp leaves(_other), do: []
end
