defmodule Engram.Indexing.VectorCache do
  @moduledoc """
  Encrypted per-user dense vector cache (chunker v5 Task 12): a text is paid to
  Voyage once per user, model and shape. Re-chunks, retries after a crash, a
  429 halfway through a note, a cross-node retry and the v5 rebuild all read
  the vector back instead of paying again. Off unless `:vector_cache_enabled`
  (`VECTOR_CACHE_ENABLED=true`); off, nothing here runs.

  ## Key

      digest = SHA-256("v1|" <> model <> "|" <> dims <> "|" <> dtype <> "|" <> input_type <> "|" <> normalize(text))
      key    = HMAC-SHA256(content_key, digest)

  `content_key` is the user's DEK-derived content-hash subkey
  (`Crypto.dek_content_hash_key/1`), so equal text under two users gives two
  unrelated keys: no cross-tenant equality leaks, and no unkeyed hash of user
  text is ever stored. A change of model, dims, dtype or input type misses.
  `normalize/1` is NFC with `\\p{Cf}` stripped, so a zero-width space or an NFD
  copy of the same words hits.

  HMAC over the digest rather than the raw text is what makes a DEK rotation
  free: the digest rides inside the ciphertext, so `rotate/3` re-keys every row
  under the new subkey without the text and without Voyage.

  ## Value

  AES-256-GCM under the user's DEK (`Envelope`, format 0: incompressible, so it
  is not in the compression policy and the `EnvelopeFormat` re-encode never
  visits it). Plaintext is `digest (32 B) <> f16 vector` (2,048 B at 1,024
  dims): the new collection stores `dense` as float16, so f16 is exactly what
  Qdrant keeps. AAD is `"embedding_cache:" <> user_id <> ":" <> hex(key)`, so a
  row copied to another user or key fails to open. A row that fails to open is
  a miss; the write that follows overwrites it.

  ## Size

  Per row: tuple ~2,230 B (ciphertext 2,096 + nonce 12 + key 32 + ids, header,
  alignment), stored inline (STORAGE PLAIN, see the migration), so 3 rows fill
  an 8 KB page (~2,730 B a row), plus ~76 B of primary key and ~32 B of note
  index: about 2,840 B a row. A Pro user at a 340,000-point index is ~0.97 GB.
  Bounded per user at `:vector_cache_max_rows_per_user` (default 400,000,
  ~1.1 GB) by `prune/1`, which also drops rows unused for 30 days. A Free user
  cannot get near it: its embed bucket pays for ~12,000 chunks a year.
  """
  import Ecto.Query

  alias Engram.Crypto.Envelope
  alias Engram.Indexing.VectorCache.Entry
  alias Engram.Repo

  @version "v1"
  @table "embedding_cache"
  @put_rows 1_000
  @touch_after_days 1
  @retention_days 30
  @max_rows_per_user 400_000

  # One statement: the hits, and a touch of those not used within a day.
  @get_many_sql """
  WITH hit AS (
    SELECT key, vector_ciphertext, vector_nonce, last_used_at
    FROM #{@table} WHERE user_id = $1 AND key = ANY($2)
  ), touch AS (
    UPDATE #{@table} e SET last_used_at = now() FROM hit
    WHERE e.user_id = $1 AND e.key = hit.key
      AND hit.last_used_at < now() - make_interval(days => #{@touch_after_days})
  )
  SELECT key, vector_ciphertext, vector_nonce FROM hit
  """

  # Five array parameters whatever the row count.
  @put_many_sql """
  INSERT INTO #{@table} (user_id, key, note_id, vector_ciphertext, vector_nonce)
  SELECT $1, k, $2, c, n FROM unnest($3::bytea[], $4::bytea[], $5::bytea[]) AS t(k, c, n)
  ON CONFLICT (user_id, key) DO UPDATE
    SET vector_ciphertext = EXCLUDED.vector_ciphertext,
        vector_nonce = EXCLUDED.vector_nonce,
        note_id = EXCLUDED.note_id,
        last_used_at = now()
  """

  @type key :: <<_::256>>
  @type digest :: <<_::256>>

  @doc "True when the cache is on. Default off."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:engram, :vector_cache_enabled, false)

  @doc "NFC, then every `\\p{Cf}` (format) code point removed."
  @spec normalize(iodata()) :: binary()
  def normalize(text) do
    bin = IO.iodata_to_binary(text)

    case :unicode.characters_to_nfc_binary(bin) do
      nfc when is_binary(nfc) -> String.replace(nfc, ~r/\p{Cf}/u, "")
      # Not valid UTF-8: hashed as given, still keyed and still exact.
      _ -> bin
    end
  end

  @doc "The input digest: model, shape and normalized text."
  @spec digest(iodata(), keyword()) :: digest()
  def digest(text, opts) do
    :crypto.hash(:sha256, [
      @version,
      "|",
      to_string(Keyword.fetch!(opts, :model)),
      "|",
      Integer.to_string(Keyword.fetch!(opts, :dims)),
      "|",
      Keyword.fetch!(opts, :dtype),
      "|",
      Keyword.fetch!(opts, :input_type),
      "|",
      normalize(text)
    ])
  end

  @doc "The cache key for a digest under a user's content-hash subkey."
  @spec key_for_digest(binary(), digest()) :: key()
  def key_for_digest(<<_::256>> = content_key, <<_::256>> = digest),
    do: :crypto.mac(:hmac, :sha256, content_key, digest)

  @doc "`key_for_digest(content_key, digest(text, opts))`."
  @spec key(binary(), iodata(), keyword()) :: key()
  def key(content_key, text, opts), do: key_for_digest(content_key, digest(text, opts))

  @doc """
  The cached vectors for `keys`, as packed float32 LE (the embed path's form,
  widened from the stored f16). One query, which also stamps `last_used_at`
  on hits not touched within a day. Missing or unreadable rows are absent.
  """
  @spec get_many(String.t(), <<_::256>>, [key()]) :: %{key() => binary()}
  def get_many(_user_id, _dek, []), do: %{}

  def get_many(user_id, <<_::256>> = dek, keys) when is_list(keys) do
    {:ok, %{rows: rows}} =
      Repo.with_tenant(user_id, fn ->
        Repo.query!(@get_many_sql, [Ecto.UUID.dump!(user_id), Enum.uniq(keys)])
      end)

    hits =
      for [key, ct, nonce] <- rows,
          {:ok, <<_digest::binary-32, f16::binary>>} <-
            [Envelope.decrypt(ct, nonce, dek, aad(user_id, key))],
          into: %{},
          do: {key, f16_to_f32(f16)}

    :telemetry.execute(
      [:engram, :vector_cache, :lookup],
      %{hits: map_size(hits), misses: length(keys) - map_size(hits)},
      %{}
    )

    hits
  end

  @doc """
  Stores `{key, digest, packed_f32}` entries for `note_id`, encrypted under
  `dek`. Batched (`#{@put_rows}` rows a statement, five array parameters, so
  the 65,535-parameter limit never binds). Overwrites an existing key.
  """
  @spec put_many(String.t(), String.t() | nil, <<_::256>>, [{key(), digest(), binary()}]) :: :ok
  def put_many(_user_id, _note_id, _dek, []), do: :ok

  def put_many(user_id, note_id, <<_::256>> = dek, entries) do
    uid = Ecto.UUID.dump!(user_id)
    nid = note_id && Ecto.UUID.dump!(note_id)

    entries
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.chunk_every(@put_rows)
    |> Enum.each(fn batch ->
      {keys, cts, nonces} =
        batch
        |> Enum.map(fn {key, digest, f32} ->
          {ct, nonce} = Envelope.encrypt(digest <> f32_to_f16(f32), dek, aad(user_id, key))
          {key, ct, nonce}
        end)
        |> unzip3()

      Repo.with_tenant!(user_id, fn ->
        Repo.query!(@put_many_sql, [uid, nid, keys, cts, nonces])
      end)

      :telemetry.execute(
        [:engram, :vector_cache, :write],
        %{rows: length(keys), bytes: cts |> Enum.map(&byte_size/1) |> Enum.sum()},
        %{}
      )
    end)
  end

  @doc """
  DEK rotation (`UserDekRotation`): every row re-encrypted under `new_dek` and
  re-keyed under its content-hash subkey, from the digest inside the
  ciphertext. No text and no Voyage call. Resumable: a row that already opens
  under the new DEK is skipped, one that opens under neither is dropped (a
  cache row is only ever worth one embed).
  """
  @spec rotate(String.t(), <<_::256>>, <<_::256>>) :: :ok
  def rotate(user_id, <<_::256>> = old_dek, <<_::256>> = new_dek) do
    new_content_key = Engram.Crypto.dek_content_hash_key_from_bytes(new_dek)
    rotate_loop(user_id, old_dek, new_dek, new_content_key, <<>>)
  end

  defp rotate_loop(user_id, old_dek, new_dek, new_content_key, after_key) do
    rows =
      Repo.with_tenant!(user_id, fn ->
        from(e in Entry,
          where: e.user_id == ^user_id and e.key > ^after_key,
          order_by: e.key,
          limit: 500,
          select: {e.key, e.note_id, e.vector_ciphertext, e.vector_nonce}
        )
        |> Repo.all()
      end)

    if rows != [] do
      {moved, gone} =
        Enum.reduce(rows, {[], []}, fn {key, note_id, ct, nonce}, {moved, gone} ->
          case Envelope.decrypt(ct, nonce, old_dek, aad(user_id, key)) do
            {:ok, <<digest::binary-32, f16::binary>>} ->
              new_key = key_for_digest(new_content_key, digest)
              {[{new_key, note_id, digest, f16} | moved], [key | gone]}

            _ ->
              case Envelope.decrypt(ct, nonce, new_dek, aad(user_id, key)) do
                {:ok, _} -> {moved, gone}
                _ -> {moved, [key | gone]}
              end
          end
        end)

      inserts =
        for {key, note_id, digest, f16} <- moved do
          {ct, nonce} = Envelope.encrypt(digest <> f16, new_dek, aad(user_id, key))

          %{
            user_id: user_id,
            key: key,
            note_id: note_id,
            vector_ciphertext: ct,
            vector_nonce: nonce
          }
        end

      # Insert before delete: a crash in between leaves the old row, which the
      # next run re-keys again (`on_conflict: :nothing`) and then deletes.
      Repo.with_tenant!(user_id, fn ->
        Repo.insert_all(Entry, inserts, on_conflict: :nothing)

        from(e in Entry, where: e.user_id == ^user_id and e.key in ^gone)
        |> Repo.delete_all()
      end)

      rotate_loop(user_id, old_dek, new_dek, new_content_key, rows |> List.last() |> elem(0))
    else
      :ok
    end
  end

  @doc """
  Retention, cross-tenant (`Repo.maintenance/0`): rows unused for 30 days go,
  then each user over `max_rows` keeps its most recently used rows. Returns
  the rows deleted. ponytail: the per-user bound is one window scan over the
  table; move to a per-user count if the table outgrows a daily scan.
  """
  @spec prune(module()) :: non_neg_integer()
  def prune(repo) do
    max_rows = Application.get_env(:engram, :vector_cache_max_rows_per_user, @max_rows_per_user)

    Repo.cross_tenant(fn ->
      %{num_rows: stale} =
        repo.query!(
          "DELETE FROM #{@table} WHERE last_used_at < now() - make_interval(days => $1)",
          [@retention_days]
        )

      %{num_rows: over} =
        repo.query!(
          """
          DELETE FROM #{@table} e USING (
            SELECT user_id, key FROM (
              SELECT user_id, key,
                     row_number() OVER (PARTITION BY user_id ORDER BY last_used_at DESC) AS rn
              FROM #{@table}
            ) ranked WHERE rn > $1
          ) d WHERE e.user_id = d.user_id AND e.key = d.key
          """,
          [max_rows]
        )

      stale + over
    end)
  end

  defp aad(user_id, key), do: "embedding_cache:" <> user_id <> ":" <> Base.encode16(key)

  @doc false
  def f32_to_f16(packed),
    do: for(<<f::float-32-little <- packed>>, into: <<>>, do: <<f::float-16-little>>)

  @doc false
  def f16_to_f32(packed),
    do: for(<<f::float-16-little <- packed>>, into: <<>>, do: <<f::float-32-little>>)

  defp unzip3(triples) do
    {a, b, c} =
      Enum.reduce(triples, {[], [], []}, fn {x, y, z}, {a, b, c} ->
        {[x | a], [y | b], [z | c]}
      end)

    {Enum.reverse(a), Enum.reverse(b), Enum.reverse(c)}
  end
end
