defmodule Engram.Workers.ReconcileNotePayloads do
  @moduledoc """
  Heals Qdrant points whose note-level payload (the filter HMACs and dates,
  `Engram.Indexing.expected_note_payload/1`) no longer matches their note's
  row, one user per chain. Run by the `NotePayloadStamps` data migration and
  enqueued by every DEK rotation right after its flip.

  The case it exists for: every filter HMAC derives from the DEK. A rotation
  rekeys the rows, and the points follow here, outside the rotation (no
  Qdrant call may sit before the rotation's flip). A rotation before this
  worker existed left the points on the old key for good.

  Two reasons select a note. A NULL `payload_hash` (below), and a payload
  version behind `PayloadV6.version/0` (`note_index_state.payload_version`,
  NULL = the baseline, compared with `<`): that note's drifted v5 points are
  merged with ONE `Qdrant.set_payloads/2` batch per page, then it is stamped.
  No read of the old payload beyond the drift check, no upsert, no PUT, no
  embedder call. While the version equals the baseline the second reason
  selects nothing (`docs/context/payload-v6.md`).

  A note is checked while its `payload_hash` is NULL. Its points are READ
  (payload keys only); if every one already holds the expected payload the
  row is just stamped, otherwise the drifted ones are rewritten with
  `set_payload` (never an upsert: vectors and text are untouched, no
  embedder call) and its `keyword_version` is cleared, because the sparse
  vectors are keyed on the same filter key. The stamp is a compare-and-set,
  so a concurrent index wins. A note whose points are all gone is stamped
  too: the next index re-creates them.

  Both layouts. A v3 point gets `expected_note_payload/1` merged in; a v5
  point (#2087's short-key layout) gets `expected_v5_payload/2`, built from
  the decrypted note as a pass builds it, and REPLACED (`overwrite_payload`).
  A v5 note whose ciphertext fails AEAD under the current DEK
  (`{:error, :decrypt_failed}`; any other error is transient and fails the
  job) cannot be healed: it is counted
  (`skipped_v5`) and marked with `undecryptable_stamp/0` in `payload_hash`,
  so the daily re-check does not requeue its user forever. Never deleted;
  the stamp matches no real hash, so the note's next index pass refreshes
  its points and stamps the real one.

  Every note row is read fresh per batch, so an edit that commits after a
  rotation's flip is healed with its own keys, and one whose index already
  re-stamped `payload_hash` is not selected at all.

  Rate-limited: one batch of 200 notes costs one scroll per 2048 points plus
  a `set_payload` per drifted note, with a pause between batches, on the
  single-slot `crdt_backfill` lane. Qdrant refusals and unapplied waits
  snooze; a 4xx (a request Qdrant refuses on every attempt) cancels the job
  once, logged with its status, and the hourly re-check retries the user. Each hop logs its counts and emits
  `[:engram, :indexing, :payload_reconcile]` per outcome
  (`Engram.PromEx.Indexing`).
  """
  # One chain per user, as `BackfillLinkKeys`: `:executing` is not a unique
  # state, so a job can insert its own successor.
  use Oban.Worker,
    queue: :crdt_backfill,
    priority: 3,
    max_attempts: 5,
    unique: [keys: [:user_id], period: :infinity, states: [:available, :scheduled, :retryable]]

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Backfill.TenantScan
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Indexing
  alias Engram.Indexing.PayloadV6
  alias Engram.Logger.Metadata
  alias Engram.Notes.{Chunk, Note, NoteBody, NoteIndexState}
  alias Engram.Repo
  alias Engram.Vector.PayloadKeys
  alias Engram.Vector.Qdrant

  require Logger

  @batch_size 200
  # Ops per `set_payloads` request (one point per op).
  @refresh_page 256
  @event [:engram, :indexing, :payload_reconcile]
  @cancelled_event [:engram, :indexing, :payload_reconcile_cancelled]
  @zero %{checked: 0, drifted: 0, rewritten: 0, skipped_v5: 0}
  @budget_ms 30_000
  # Between batches, so a large vault never saturates Qdrant.
  @pause_ms 200

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id} = args} = job) do
    with %User{} = user <- Repo.get(User, user_id),
         :ok <- RotationGate.check_user(user) do
      deadline = System.monotonic_time(:millisecond) + @budget_ms
      {result, counts} = heal(user, args["after"], deadline, @zero)
      report(user_id, counts)

      case result do
        :done ->
          :ok

        {:more, after_id} ->
          {:ok, _} = Oban.insert(new(%{"user_id" => user_id, "after" => after_id}))
          :ok

        other ->
          other
      end
    else
      nil -> :ok
      {:error, :rotation_in_progress} -> locked_snooze(user_id, job)
    end
  end

  # A crashed rotation keeps its lock on purpose (an operator must clear it),
  # and the heal must not write under it, so it keeps snoozing. After an
  # hour of that, one warning per job.
  @lock_warn_after 60
  defp locked_snooze(user_id, %Oban.Job{meta: meta}) do
    if (meta["snoozed"] || 0) == @lock_warn_after do
      Logger.warning(
        "note payload reconcile: rotation lock held for an hour, still waiting",
        Metadata.with_category(:warning, :oban, user_id: user_id)
      )
    end

    {:snooze, 60}
  end

  @doc "Enqueues a chain for every user with an unstamped indexed note. Returns how many."
  @spec enqueue_missing() :: non_neg_integer()
  def enqueue_missing do
    user_ids =
      TenantScan.flat_map_users(fn uid ->
        if Repo.exists?(where(unstamped(), [n], n.user_id == ^uid)), do: [uid], else: []
      end)

    executing = Engram.Backfill.TenantScan.executing_user_ids(__MODULE__)

    # One insert per user: Oban's Basic engine ignores `unique` in insert_all.
    for uid <- user_ids,
        not MapSet.member?(executing, uid),
        do: {:ok, _} = Oban.insert(new(%{"user_id" => uid}))

    length(user_ids)
  end

  # The done predicate and the worker's selection, one definition: an
  # unstamped note, or one whose points were written with an older payload
  # version (`PayloadV6.version/0`; NULL counts as the baseline). While the
  # version equals the baseline no note can be behind, so the term is left out.
  defp unstamped do
    from(n in Note,
      as: :note,
      where:
        n.kind == "note" and
          exists(
            from(c in Chunk,
              where: c.note_id == parent_as(:note).id and not is_nil(c.qdrant_point_id)
            )
          )
    )
    |> where(^unstamped_or_stale())
  end

  defp unstamped_or_stale do
    version = PayloadV6.version()
    base = PayloadV6.baseline()

    if version > base do
      dynamic(
        [note: n],
        is_nil(n.payload_hash) or
          exists(
            from(s in NoteIndexState,
              where:
                s.note_id == parent_as(:note).id and coalesce(s.payload_version, ^base) < ^version
            )
          )
      )
    else
      dynamic([note: n], is_nil(n.payload_hash))
    end
  end

  defp heal(%User{id: user_id} = user, after_id, deadline, counts) do
    {notes, points} = batch(user_id, after_id)

    cond do
      notes == [] ->
        {:done, counts}

      System.monotonic_time(:millisecond) > deadline ->
        {{:more, after_id}, counts}

      true ->
        with {:ok, stored} <- read_payloads(user_id, points |> Map.values() |> List.flatten()),
             # Per batch, after the read and before any write: a rotation
             # that started since would have its fresh keys overwritten.
             :ok <- RotationGate.check(user_id),
             {:ok, counts} <- heal_notes(user, notes, points, stored, counts) do
          if length(notes) < @batch_size do
            {:done, counts}
          else
            Process.sleep(@pause_ms)
            heal(user, List.last(notes).id, deadline, counts)
          end
        else
          {:error, reason, counts} -> {answer(user_id, reason), counts}
          {:error, reason} -> {answer(user_id, reason), counts}
        end
    end
  end

  # One line per failed hop with the reason's class (status and tag, never a
  # body, an id list or note content), then the Oban answer.
  defp answer(user_id, reason) do
    result = qdrant_answer(reason)

    # The hourly re-check retries a cancelled user, so a refusal no fix has
    # cleared cancels once an hour forever: this counter is what alerts on it.
    if match?({:cancel, _}, result),
      do: :telemetry.execute(@cancelled_event, %{count: 1}, %{http_status: http_status(reason)})

    if match?({tag, _} when tag in [:error, :cancel], result) do
      Logger.warning(
        "note payload reconcile failed",
        Metadata.with_category(:warning, :oban,
          user_id: user_id,
          reason_label: Metadata.safe_reason(reason),
          result: elem(result, 0)
        )
      )
    end

    result
  end

  # As every other Qdrant writer: refusal and an unapplied wait are snoozes,
  # not attempts (five of those and the job is discarded into the same
  # pressure). A 4xx Qdrant refusal (a filter on an unindexed key, a bad
  # request shape) fails the same way on every attempt: cancel once, the
  # hourly re-check retries the user after a fix ships (#2138). A 5xx or a
  # transport error (timeout) keeps Oban's backoff.
  defp qdrant_answer(:rotation_in_progress), do: {:snooze, 60}
  defp qdrant_answer(:user_not_found), do: :ok
  defp qdrant_answer(:qdrant_backpressure), do: Qdrant.backpressure_snooze(:refused)
  defp qdrant_answer(:qdrant_wait_timeout), do: Qdrant.wait_timeout_snooze()

  defp qdrant_answer(reason) do
    case http_status(reason) do
      status when status in [429, 503, 507] -> Qdrant.backpressure_snooze(:refused)
      status when status in 400..499 -> {:cancel, reason}
      _ -> {:error, reason}
    end
  end

  # `scroll/2` and the payload writes (`write_error/2`) tag a refusal differently.
  defp http_status({:qdrant_scroll, status, _body}) when is_integer(status), do: status
  defp http_status({status, _body}) when is_integer(status), do: status
  defp http_status(_reason), do: nil

  defp batch(user_id, after_id) do
    query =
      from(n in unstamped(), where: n.user_id == ^user_id, order_by: n.id, limit: @batch_size)

    query = if after_id, do: where(query, [n], n.id > ^after_id), else: query

    {:ok, result} =
      Repo.with_tenant(user_id, fn ->
        notes = Repo.all(NoteBody.select_note(query))
        ids = Enum.map(notes, & &1.id)

        points =
          from(c in Chunk,
            where: c.note_id in ^ids and not is_nil(c.qdrant_point_id),
            select: {c.note_id, c.qdrant_point_id}
          )
          |> Repo.all()
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

        {notes, points}
      end)

    result
  end

  # `%{point_id => payload}` for the points that exist, payload keys only.
  defp read_payloads(user_id, ids) do
    keys =
      Enum.uniq(
        v5_keys() ++
          (Indexing.expected_note_payload(%Note{}) |> Map.keys() |> Enum.map(&to_string/1))
      )

    ids
    |> Enum.chunk_every(Qdrant.max_ids())
    |> Enum.reduce_while({:ok, %{}}, fn chunk, {:ok, acc} ->
      case Qdrant.scroll(Qdrant.collection_name(),
             # The tenant condition every reader uses: `user_id` OR `u` while
             # legacy filters are on, `u` alone once they are off. Never a
             # hand-built condition: strict mode answers 400 to a filter on
             # an unindexed key (#2138). Both layouts still come back.
             filter: %{must: [%{has_id: chunk}, Qdrant.match_filter(:user, user_id)]},
             with_payload: keys,
             limit: length(chunk)
           ) do
        {:ok, %{points: points}} ->
          {:cont, {:ok, Enum.into(points, acc, &{&1["id"], &1["payload"] || %{}})}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
  end

  @undecryptable "undecryptable"

  @doc """
  The `payload_hash` of a note the heal could not decrypt. Not a SHA-256
  (a real stamp is 32 bytes), so it never vouches for any payload.
  """
  def undecryptable_stamp, do: @undecryptable

  # CAS on the row as read (an edit since then re-indexes and stamps it) and
  # on the user's DEK version: a rotation flip in between NULLs every stamp,
  # and the row may open under the new DEK.
  defp mark_undecryptable(note, user) do
    {:ok, {_, _}} =
      Repo.with_tenant(note.user_id, fn ->
        same_content =
          if note.content_hash,
            do: dynamic([n], n.content_hash == ^note.content_hash),
            else: dynamic([n], is_nil(n.content_hash))

        from(n in Note,
          where: n.kind == "note" and n.id == ^note.id and is_nil(n.payload_hash),
          where: ^same_content,
          where: exists(same_dek(user))
        )
        |> Repo.update_all(set: [payload_hash: @undecryptable])
      end)

    :ok
  end

  defp same_dek(%User{id: id, dek_version: nil}),
    do: from(u in User, where: u.id == ^id and is_nil(u.dek_version), select: 1)

  defp same_dek(%User{id: id, dek_version: v}),
    do: from(u in User, where: u.id == ^id and u.dek_version == ^v, select: 1)

  defp heal_notes(user, notes, points, stored, counts) do
    # A note with a stamp is selected only for an old payload version: it
    # needs a rewrite, not the drift check a NULL stamp gets.
    {stale, unstamped} = Enum.split_with(notes, & &1.payload_hash)

    # A note still holding legacy-layout (v3) points is healed as an unstamped
    # one: the refresh below rewrites v5 points only, and stamping a note whose
    # points were not written would vouch for a payload they do not hold.
    {legacy, stale} = Enum.split_with(stale, &legacy_points?(&1, points, stored))

    with {:ok, counts} <- heal_unstamped(user, unstamped ++ legacy, points, stored, counts) do
      refresh_stale(user, stale, points, stored, counts)
    end
  end

  defp legacy_points?(note, points, stored),
    do: Enum.any?(Map.get(points, note.id, []), &(stored[&1] && not v5?(stored[&1])))

  defp heal_unstamped(user, notes, points, stored, counts) do
    Enum.reduce_while(notes, {:ok, counts}, fn note, {:ok, counts} ->
      present = for id <- Map.get(points, note.id, []), Map.has_key?(stored, id), do: id
      {v5_ids, v3_ids} = Enum.split_with(present, &v5?(stored[&1]))
      counts = bump(counts, :checked)

      case plan_note(user, note, v5_ids, v3_ids, stored) do
        {:ok, writes, payload} ->
          # Legacy points never take the new shape: their note is not stamped
          # with a payload version, so the sweep keeps it in view.
          heal_note(note, payload, writes, counts, v3_ids == [])

        :skip ->
          mark_undecryptable(note, user)
          {:cont, {:ok, bump(counts, :skipped_v5)}}

        {:error, reason} ->
          {:halt, {:error, reason, counts}}
      end
    end)
  end

  # Payload-version refresh: the expected payload is merged onto every v5
  # point that does not hold it, as ONE `set_payloads` batch per page (never an
  # upsert, never a PUT: vectors untouched, no embedder), then each note is
  # stamped. A note whose points all hold it is only stamped.
  # Seam for the writer flip: `Indexing.expected_v5_payload/2` is the one call
  # that becomes the v6 builder (`PayloadV6.from_rows_or_extract/4`).
  defp refresh_stale(_user, [], _points, _stored, counts), do: {:ok, counts}

  defp refresh_stale(user, notes, points, stored, counts) do
    plans =
      Enum.map(notes, fn note ->
        v5_ids = for id <- Map.get(points, note.id, []), v5_point?(stored[id]), do: id
        {note, plan_refresh(user, note, v5_ids, stored)}
      end)

    case Enum.find(plans, &match?({_, {:error, _}}, &1)) do
      {_note, {:error, reason}} -> {:error, reason, counts}
      nil -> write_refresh(plans, counts)
    end
  end

  defp v5_point?(nil), do: false
  defp v5_point?(point), do: v5?(point)

  defp plan_refresh(user, note, v5_ids, stored) do
    with {:ok, plain} <- Crypto.maybe_decrypt_note_fields(note, user),
         {:ok, v5} <- Indexing.expected_v5_payload(plain, user) do
      want = normalize(v5)
      drifted = Enum.reject(v5_ids, &(Map.take(stored[&1], v5_keys()) == want))
      # A key the new payload omits is deleted, not left behind by the merge.
      {:ok, v5, for(id <- drifted, do: {id, v5, dropped(stored[id], want)})}
    else
      {:error, :decrypt_failed} -> :skip
      {:error, reason} -> {:error, reason}
    end
  end

  defp dropped(point, want), do: Map.keys(Map.take(point, v5_keys())) -- Map.keys(want)

  defp write_refresh(plans, counts) do
    pairs = for {_note, {:ok, _payload, pairs}} <- plans, pair <- pairs, do: pair

    pairs
    |> Enum.chunk_every(@refresh_page)
    |> Enum.reduce_while(:ok, fn page, :ok ->
      case Qdrant.set_payloads(Qdrant.collection_name(), page) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
    |> case do
      :ok -> {:ok, Enum.reduce(plans, counts, &stamp_refreshed/2)}
      {:error, reason} -> {:error, reason, counts}
    end
  end

  defp stamp_refreshed({note, {:ok, payload, pairs}}, counts) do
    counts = bump(counts, :checked)
    stamp(note, payload, wrote?: pairs != [], resparse?: false, versioned?: true)
    if pairs == [], do: counts, else: counts |> bump(:drifted) |> bump(:rewritten)
  end

  # Cannot be opened under the current DEK: stamped so the sweep does not
  # select it every hour; its next index pass writes the real payload.
  defp stamp_refreshed({note, :skip}, counts) do
    stamp_version(note)
    counts |> bump(:checked) |> bump(:skipped_v5)
  end

  # `{:ok, writes, stamp_payload}`: the drifted points of each layout with
  # the payload each must hold, and the payload whose hash the row gets (the
  # v5 one when the note has v5 points, as a v5 pass stamps).
  defp plan_note(_user, note, [], v3_ids, stored) do
    payload = Indexing.expected_note_payload(note)
    {:ok, v3_writes(v3_ids, stored, payload), payload}
  end

  defp plan_note(user, note, v5_ids, v3_ids, stored) do
    with {:ok, plain} <- Crypto.maybe_decrypt_note_fields(note, user),
         {:ok, v5} <- Indexing.expected_v5_payload(plain, user) do
      want = normalize(v5)
      drifted = Enum.reject(v5_ids, &(Map.take(stored[&1], v5_keys()) == want))
      writes = if drifted == [], do: [], else: [{:overwrite, drifted, v5}]
      {:ok, writes ++ v3_writes(v3_ids, stored, Indexing.expected_note_payload(note)), v5}
    else
      # The note's own ciphertext fails AEAD under the current DEK: it is
      # undecryptable, not unlucky. Anything else (no DEK, a contended load,
      # a key-provider error) is transient: the job fails and Oban backs off,
      # the note stays NULL for the daily re-check.
      {:error, :decrypt_failed} -> :skip
      {:error, reason} -> {:error, reason}
    end
  end

  defp v3_writes(ids, stored, payload) do
    want = normalize(payload)

    case Enum.reject(ids, &holds?(stored[&1], want)) do
      [] -> []
      drifted -> [{:set, drifted, payload}]
    end
  end

  defp normalize(payload), do: payload |> Jason.encode!() |> Jason.decode!()

  defp v5_keys, do: Enum.map(PayloadKeys.logical_names(), &PayloadKeys.short/1)

  defp heal_note(note, payload, [], counts, versioned?) do
    stamp(note, payload, wrote?: false, resparse?: false, versioned?: versioned?)
    {:cont, {:ok, counts}}
  end

  defp heal_note(note, payload, writes, counts, versioned?) do
    counts = bump(counts, :drifted)

    case Enum.reduce_while(writes, :ok, fn w, :ok -> write(w) end) do
      :ok ->
        # Drifted filter keys mean a rotation, so the sparse vectors (keyed
        # on the same filter key) are stale too: the keyword sweep redoes them.
        stamp(note, payload, wrote?: true, resparse?: true, versioned?: versioned?)
        {:cont, {:ok, bump(counts, :rewritten)}}

      # Logged once, with its class, where the hop answers Oban (`answer/2`).
      {:error, reason} ->
        {:halt, {:error, reason, counts}}
    end
  end

  defp write({op, ids, payload}) do
    fun = if op == :set, do: &Qdrant.set_payload/4, else: &Qdrant.overwrite_payload/4

    case fun.(Qdrant.collection_name(), ids, payload, caller: :reconcile) do
      :ok -> {:cont, :ok}
      err -> {:halt, err}
    end
  end

  # Compare-and-set on every column the payload is built from, and on the
  # stamp still being what the batch read (NULL for a first stamp, the old hash
  # for a version refresh): an index that committed since the read wrote (and
  # stamped) its own payload, and stamping ours would vouch for HMACs the row
  # no longer holds. A miss stays as it was for the next pass. A hit also
  # stamps the payload version the points now hold.
  @payload_columns [
    :content_hash,
    :vault_id,
    :path_hmac,
    :folder_hmac,
    :tags_hmac,
    :type_hmac,
    :fm_timestamp,
    :fm_created
  ]

  defp stamp(note, payload, opts) do
    wrote? = Keyword.fetch!(opts, :wrote?)
    resparse? = Keyword.fetch!(opts, :resparse?)

    guard =
      Enum.reduce(@payload_columns, same_stamp(note), fn
        col, acc ->
          case Map.fetch!(note, col) do
            nil -> dynamic([n], ^acc and is_nil(field(n, ^col)))
            value -> dynamic([n], ^acc and field(n, ^col) == ^value)
          end
      end)

    set = [payload_hash: Indexing.note_payload_hash(payload)]
    set = if resparse?, do: [{:keyword_version, nil} | set], else: set

    {:ok, :ok} =
      Repo.with_tenant(note.user_id, fn ->
        case Repo.update_all(from(n in Note, where: n.kind == "note", where: ^guard), set: set) do
          # We wrote this note's points from the row we read and the stamp
          # missed: an index committed (and stamped) in between, and our
          # write may have replaced its fresher payload.
          {0, _} when wrote? -> Indexing.unstamp_payload_hash(note)
          {0, _} -> :ok
          {_, _} -> if Keyword.fetch!(opts, :versioned?), do: put_version(note), else: :ok
        end
      end)

    :ok
  end

  defp same_stamp(%{payload_hash: nil, id: id}),
    do: dynamic([n], n.id == ^id and is_nil(n.payload_hash))

  defp same_stamp(%{payload_hash: hash, id: id}),
    do: dynamic([n], n.id == ^id and n.payload_hash == ^hash)

  defp stamp_version(note),
    do: elem(Repo.with_tenant(note.user_id, fn -> put_version(note) end), 0)

  # Never lowers a newer stamp (`<` everywhere: a newer stamp is current).
  defp put_version(note) do
    version = PayloadV6.version()

    from(s in NoteIndexState,
      where: s.note_id == ^note.id,
      where: is_nil(s.payload_version) or s.payload_version < ^version
    )
    |> Repo.update_all(set: [payload_version: version])

    :ok
  end

  # A v3 point always carries `user_id` (`Indexing.expected_note_payload/1`);
  # a v5 one carries `u` instead.
  defp v5?(point), do: Map.has_key?(point, "u") or not Map.has_key?(point, "user_id")

  # A null and an absent key are the same to a filter.
  defp holds?(point, want), do: Enum.all?(want, fn {k, v} -> Map.get(point, k) == v end)

  defp bump(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  # One line per hop, and a counter per outcome, so a deploy can tell a heal
  # that verifies from one that rewrites the collection.
  defp report(user_id, counts) do
    for {outcome, n} <- counts,
        do: :telemetry.execute(@event, %{count: n}, %{outcome: outcome})

    Logger.info(
      "note payload reconcile hop",
      Metadata.with_category(:info, :oban, [user_id: user_id] ++ Map.to_list(counts))
    )
  end
end
