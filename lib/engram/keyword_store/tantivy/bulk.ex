defmodule Engram.KeywordStore.Tantivy.Bulk do
  @moduledoc """
  Pushes notes straight to kwsearch's bulk endpoint (`POST /bulk`): the
  first load of existing notes and every reconcile repair (search storage
  roadmap P2 task 5). Never through `keyword_feed` (security F2, Todd
  2026-11-26): a full backfill leaves the feed exactly as it was.

  ## Ordering against live traffic

  A batch is read and pushed later, while the feed keeps applying edits and
  deletes, so each note is read the way a feed pass writes:

    * the note rows are locked (`ChunkRows.lock_notes!/1`, the index pass's
      lock order) and each note takes the next `keyword_stamp_seq` stamp under
      that lock, then its chunk rows and content are read in the same
      transaction. A pass that committed before the lock is in the read with
      a lower stamp; one after it waits for the lock and takes a higher
      stamp. So the batch's stamp orders it against every feed op of the
      note, and kwsearch drops a batch note older than the note's applied
      stamp (`Shard::bulk`), deletes included.
    * the batch carries `xmax` of the reading snapshot (feed marker expiry)
      and its read time: kwsearch refuses a batch older than an hour, the
      time it keeps a note's applied stamp after the feed no longer needs it.
    * a user or vault deleted after the read is dropped against its
      tombstone in kwsearch.

  A note that is gone or trashed when read is pushed with an empty point set
  (the reconcile's orphan repair); one never seen anywhere is skipped. Every
  query runs in `Repo.with_tenant/2` for the batch's user (security F7).
  """

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.Indexing.ChunkRows
  alias Engram.KeywordStore.Tantivy
  alias Engram.KeywordStore.Tantivy.Client
  alias Engram.Logger.Metadata
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Repo

  require Logger

  # One request's body budget and note count (kwsearch caps at 16 MiB and
  # 1,000 notes); a note bigger than the budget goes alone, in parts.
  @batch_bytes 2_000_000
  @batch_notes 500

  @type counts :: %{
          applied: non_neg_integer(),
          stale: non_neg_integer(),
          tomb: non_neg_integer(),
          skipped: non_neg_integer()
        }

  @doc """
  Reads `note_ids` of `user` under their locks and pushes them. `vaults`
  maps a note id to its vault for notes that may be gone from Postgres (from
  kwsearch's listing), so their docs can be removed.
  """
  @spec push(map(), [String.t()], %{String.t() => String.t()}) ::
          {:ok, counts()} | {:error, term()}
  def push(user, note_ids, vaults \\ %{})

  def push(_user, [], _vaults), do: {:ok, %{applied: 0, stale: 0, tomb: 0, skipped: 0}}

  def push(user, note_ids, vaults) do
    user_id = to_string(user.id)
    read_at = System.system_time(:second)
    read = read(user_id, note_ids)

    {notes, skipped} =
      Enum.reduce(note_ids, {[], 0}, fn id, {acc, skipped} ->
        case note(user, read, id, vaults) do
          {:ok, n} -> {[n | acc], skipped}
          :skip -> {acc, skipped + 1}
        end
      end)

    notes
    |> Enum.reverse()
    |> Enum.flat_map(&parts/1)
    |> batches()
    |> Enum.reduce_while({:ok, %{applied: 0, stale: 0, tomb: 0, skipped: skipped}}, fn batch,
                                                                                       {:ok, acc} ->
      case Client.bulk(user_id, read_at, batch) do
        {:ok, got} -> {:cont, {:ok, add(acc, got)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  The locked read: per note its stamp, its live row (nil when gone or
  trashed) and its stored point rows, plus the snapshot xmax. Public for the
  ordering tests.
  """
  @spec read(String.t(), [String.t()]) :: %{
          xmax: non_neg_integer(),
          stamps: %{String.t() => pos_integer()},
          notes: %{String.t() => Note.t()},
          rows: %{String.t() => list()}
        }
  def read(user_id, note_ids) do
    {:ok, read} =
      Repo.with_tenant(user_id, fn ->
        :ok = ChunkRows.lock_notes!(note_ids)

        %{rows: [[xmax]]} =
          Repo.query!("SELECT pg_snapshot_xmax(pg_current_snapshot())::text", [])

        %{rows: stamps} =
          Repo.query!("SELECT nextval('keyword_stamp_seq') FROM generate_series(1, $1)", [
            length(note_ids)
          ])

        notes = Notes.live_notes_for_worker(note_ids, user_id)

        %{
          xmax: String.to_integer(xmax),
          stamps: Map.new(Enum.zip(note_ids, List.flatten(stamps))),
          notes: Map.new(notes, &{&1.id, &1}),
          rows: Indexing.stored_rows_by_note(user_id, note_ids)
        }
      end)

    read
  end

  defp note(user, read, id, vaults) do
    base = %{note: id, stamp: Map.fetch!(read.stamps, id), xmax: read.xmax}

    case Map.fetch(read.notes, id) do
      {:ok, note} -> live(user, note, Map.get(read.rows, id, []), base)
      # Gone or trashed: its docs go, if kwsearch says where they are.
      :error -> gone(Map.get(vaults, id), base)
    end
  end

  defp gone(nil, _base), do: :skip
  defp gone(vault, base), do: {:ok, Map.merge(base, %{vault: vault, keep: [], docs: []})}

  defp live(user, note, rows, base) do
    keep = Enum.map(rows, &elem(&1, 1))

    with {:ok, note} <- Crypto.maybe_decrypt_note_fields(note, user),
         {:ok, docs, key} <- Indexing.keyword_docs(note, user, rows) do
      {:ok,
       Map.merge(base, %{
         vault: note.vault_id,
         keep: keep,
         docs: Tantivy.feed_terms(docs, key)
       })}
    else
      other ->
        # Skipped, not pushed half-read: the next reconcile walk retries it.
        Logger.warning(
          "keyword bulk: note skipped",
          Metadata.with_category(:warning, :search,
            user_id: user.id,
            note_id: note.id,
            reason: Metadata.safe_reason(other)
          )
        )

        :skip
    end
  end

  # A note as request parts at one stamp: every part names the full point
  # set, so kwsearch applies the first and treats the rest as its
  # continuation (equal stamp).
  defp parts(%{docs: docs} = n) do
    head = %{
      vault: n.vault,
      note: n.note,
      stamp: n.stamp,
      xmax: n.xmax,
      keep_b64: Client.encode_ids(n.keep)
    }

    docs
    |> Enum.map(fn {id, terms} -> %{point: id, terms_b64: Base.encode64(terms)} end)
    |> Enum.chunk_while(
      {[], byte_size(head.keep_b64)},
      fn doc, {acc, bytes} ->
        size = byte_size(doc.terms_b64) + 64

        if acc != [] and bytes + size > @batch_bytes,
          do: {:cont, Enum.reverse(acc), {[doc], byte_size(head.keep_b64) + size}},
          else: {:cont, {[doc | acc], bytes + size}}
      end,
      fn {acc, _} -> {:cont, Enum.reverse(acc), nil} end
    )
    |> Enum.map(&Map.put(head, :docs, &1))
  end

  defp batches(parts) do
    Enum.chunk_while(
      parts,
      {[], 0},
      fn part, {acc, bytes} ->
        size = size(part)

        if acc != [] and (bytes + size > @batch_bytes or length(acc) >= @batch_notes),
          do: {:cont, Enum.reverse(acc), {[part], size}},
          else: {:cont, {[part | acc], bytes + size}}
      end,
      fn
        {[], _} -> {:cont, nil}
        {acc, _} -> {:cont, Enum.reverse(acc), nil}
      end
    )
  end

  defp size(part),
    do:
      byte_size(part.keep_b64) + Enum.reduce(part.docs, 200, &(&2 + byte_size(&1.terms_b64) + 64))

  defp add(acc, got) do
    %{
      acc
      | applied: acc.applied + Map.get(got, "applied", 0),
        stale: acc.stale + Map.get(got, "stale", 0),
        tomb: acc.tomb + Map.get(got, "tomb", 0)
    }
  end
end
