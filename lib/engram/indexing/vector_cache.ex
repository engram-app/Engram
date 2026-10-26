defmodule Engram.Indexing.VectorCache do
  @moduledoc """
  Short-lived encrypted per-user dense vector cache (chunker v5 Task 12). Its
  job is pay-once across retries, crashes and the v5 rebuild window: a 429
  halfway through a note, a crash between the embed and the commit, a retry
  on another node or after a Spot interruption, and duplicate texts inside one
  rebuild pass all read the vector back instead of paying Voyage again. It is
  NOT a permanent second copy of the index: unchanged chunks are already
  reused by the `plan_chunks` fingerprint, so a row is worth keeping only for
  as long as a retry can still come. Rows expire 72 h after insert.

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
  index: about 2,840 B a row. Retention is 72 h by `inserted_at` (no touch on
  hit: a full page leaves no room for a HOT update, so a touch would rewrite a
  2.8 KB tuple), deleted by `prune/1` in batches of 10,000 rows. So
  the table holds about three days of embed volume: ~0.6 to 1 GB at the peak
  of the v5 rebuild (~340,000 vectors), megabytes in steady state.

  ## Writes refused

  A write is skipped, never raised: while the user's DEK rotation holds its
  lock or after the DEK version moved past the one the pass read (the row
  would sit under a retired key, behind the rotation's scan), and when the
  note was deleted mid-embed (the `note_id` FK). Both are counted as
  `[:engram, :vector_cache, :skipped]`.
  """
  import Ecto.Query

  alias Engram.Crypto.Envelope
  alias Engram.Indexing.VectorCache.Entry
  alias Engram.Repo

  @version "v1"
  @table "embedding_cache"
  @put_rows 1_000
  @retention_hours 72
  @prune_batch 10_000

  @get_many_sql """
  SELECT key, vector_ciphertext, vector_nonce
  FROM #{@table} WHERE user_id = $1 AND key = ANY($2)
  """

  # Six parameters whatever the row count. Writes nothing while the user's
  # DEK rotation is running or once the DEK version moved past `$6` (nil:
  # no version check), so no row lands under a key being rotated away.
  # `FOR SHARE` makes the check a lock: `RotationLock.acquire/1` updates the
  # same users row, so it waits for an in-flight write to commit, and the
  # rotation's scan then sees (and re-keys) that row.
  @put_many_sql """
  INSERT INTO #{@table} (user_id, key, note_id, vector_ciphertext, vector_nonce)
  SELECT $1, k, $2, c, n FROM unnest($3::bytea[], $4::bytea[], $5::bytea[]) AS t(k, c, n)
  WHERE EXISTS (
    SELECT 1 FROM users u
    WHERE u.id = $1 AND u.dek_rotation_locked_at IS NULL
      AND ($6::integer IS NULL OR coalesce(u.dek_version, 1) = $6::integer)
    FOR SHARE
  )
  ON CONFLICT (user_id, key) DO UPDATE
    SET vector_ciphertext = EXCLUDED.vector_ciphertext,
        vector_nonce = EXCLUDED.vector_nonce,
        note_id = EXCLUDED.note_id
  """

  @type key :: <<_::256>>
  @type digest :: <<_::256>>

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
  @spec key_for_digest(<<_::256>>, digest()) :: key()
  def key_for_digest(<<_::256>> = content_key, <<_::256>> = digest),
    do: :crypto.mac(:hmac, :sha256, content_key, digest)

  @doc "`key_for_digest(content_key, digest(text, opts))`."
  @spec key(<<_::256>>, iodata(), keyword()) :: key()
  def key(content_key, text, opts), do: key_for_digest(content_key, digest(text, opts))

  @doc """
  The cached vectors for `keys`, as packed float32 LE (the embed path's form,
  widened from the stored f16). One read-only query. Missing or unreadable
  rows are absent.
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
  `dek`, which is DEK version `dek_version` (nil skips that check). Batched
  (`#{@put_rows}` rows a statement, six parameters, so the 65,535-parameter
  limit never binds). Overwrites an existing key. Never raises on a refused
  write (see "Writes refused").
  """
  @spec put_many(
          String.t(),
          String.t() | nil,
          <<_::256>>,
          [{key(), digest(), binary()}],
          pos_integer() | nil
        ) ::
          :ok
  def put_many(user_id, note_id, dek, entries, dek_version \\ nil)
  def put_many(_user_id, _note_id, _dek, [], _dek_version), do: :ok

  def put_many(user_id, note_id, <<_::256>> = dek, entries, dek_version) do
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

      params = [uid, nid, keys, cts, nonces, dek_version]

      # A savepoint, so a FK violation (the note was hard-deleted mid-embed)
      # rolls back only this statement and the tenant block still exits clean.
      result =
        Repo.with_tenant!(user_id, fn -> Repo.query(@put_many_sql, params, mode: :savepoint) end)

      case result do
        {:ok, %{num_rows: n}} when n == length(keys) ->
          :telemetry.execute(
            [:engram, :vector_cache, :write],
            %{rows: n, bytes: cts |> Enum.map(&byte_size/1) |> Enum.sum()},
            %{}
          )

        {:ok, %{num_rows: _}} ->
          skipped(length(keys), :rotation)

        {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} ->
          skipped(length(keys), :note_deleted)

        {:error, error} ->
          raise error
      end
    end)
  end

  defp skipped(rows, reason),
    do: :telemetry.execute([:engram, :vector_cache, :skipped], %{rows: rows}, %{reason: reason})

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
        :ok = insert_rekeyed(inserts)

        {_, _} =
          Repo.delete_all(from(e in Entry, where: e.user_id == ^user_id and e.key in ^gone))

        :ok
      end)

      rotate_loop(user_id, old_dek, new_dek, new_content_key, rows |> List.last() |> elem(0))
    else
      :ok
    end
  end

  # A note deleted mid-rotation fails the FK: that batch is rewritten without
  # note ids (the 72 h expiry still reaps it) rather than aborting the
  # rotation. A savepoint, as in `put_many/5`: a nested `Repo.transaction`
  # is not one, and the retry would run in an aborted transaction.
  defp insert_rekeyed(inserts) do
    {_, _} = Repo.insert_all(Entry, inserts, on_conflict: :nothing, mode: :savepoint)
    :ok
  rescue
    e in Postgrex.Error ->
      if e.postgres.code != :foreign_key_violation, do: reraise(e, __STACKTRACE__)
      orphaned = Enum.map(inserts, &%{&1 | note_id: nil})
      {_, _} = Repo.insert_all(Entry, orphaned, on_conflict: :nothing)
      :ok
  end

  @doc """
  Retention, cross-tenant (`Repo.maintenance/0`): rows inserted more than 72 h
  ago, deleted #{@prune_batch} at a time (each its own statement, driven by
  the `inserted_at` index) until none are left. Returns the rows deleted.
  """
  @spec prune(module()) :: non_neg_integer()
  def prune(repo), do: Repo.cross_tenant(fn -> prune_loop(repo, 0) end)

  defp prune_loop(repo, total) do
    %{num_rows: n} =
      repo.query!(
        """
        DELETE FROM #{@table} WHERE ctid = ANY(ARRAY(
          SELECT ctid FROM #{@table}
          WHERE inserted_at < now() - make_interval(hours => $1)
          LIMIT $2
        ))
        """,
        [@retention_hours, @prune_batch]
      )

    if n < @prune_batch, do: total + n, else: prune_loop(repo, total + n)
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
