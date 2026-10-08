defmodule Engram.Workers.ReencodeEnvelopes do
  @moduledoc """
  Re-encodes one user's legacy (format 0, 12-byte nonce) envelopes in the
  compressible DB columns so the compression policy applies to them (#1872
  PR 3). Driven by `Engram.DataMigrations.EnvelopeFormat`.

  Re-encode = decrypt and encrypt again under the SAME DEK and the SAME AAD;
  `Envelope.encrypt/3` picks the format from the AAD. Each write sets only the
  ciphertext and nonce columns, with a compare-and-set on the old ciphertext,
  so a row edited between read and write keeps its edit (the next pass picks
  it up). `updated_at`, `version`, `seq` and `dek_version` never move, so no
  client re-pulls and no checkpoint CAS (on version + seq) conflicts.

  One side effect: rewriting `notes.crdt_state_ciphertext` fires the
  `notes_crdt_head_invalidate` trigger, which NULLs `crdt_head`.
  `WarmCrdtHeads` re-warms it within the hour; once per note is acceptable.

  No `RotationLock`: taking it would make the user's clients get HTTP 503.
  Instead every batch reloads the user and snoozes the job while a DEK
  rotation holds the lock. A rotation that starts after that check blocks on
  the rows this batch wrote and then rewraps them (format 1 under the old DEK
  is readable), and any row it already rewrapped fails the CAS. That gate plus
  the CAS is the safety; sharing `:crypto_backfill` is not (Oban OSS queue
  limits are per node).

  Bounded runs: a job works for at most `@budget_ms`, then enqueues its
  successor with its cursor (`column` + `after` id) and returns. The successor
  is inserted while this job is still `executing`, so
  `DataMigrations.jobs_in_flight?/1` never sees a gap in the chain.

  Reads only the key, the AAD id and the one ciphertext + nonce pair being
  processed, never whole rows (a note carries several ciphertext columns).
  Memory and lock time are bounded by STORED bytes, not row count: each
  200-id batch is cut into chunks of at most `@chunk_bytes` (always at least
  one row, so one huge note still progresses), each committed on its own.

  A row that does not decrypt is logged at `:warning` and left: it keeps the
  migration open and the stuck-migration alert surfaces it.

  Lifeline rescue: if a crashed predecessor is rescued after its successor was
  inserted, the rescued job cancels itself as `:superseded`. The hand-off can
  also hit the unique conflict and insert nothing, so a rescue may leave no
  chain for that user. The next hourly pass re-enqueues it (up to ~1 h delay;
  no work is lost and the migration is never falsely marked done). Per-user
  discovery inserts are not atomic across users either; a partial pass
  self-heals on the next one.

  With compression off (`Envelope.compression_on?/0`: the kill switch, or a
  cluster node that cannot read format 1), a job cancels itself: re-encoding
  would write format 0 again and NULL `crdt_head` for nothing. The migration
  is disabled by the same decision and re-enqueues once it is back on.

  Not re-encoded: attachments (format 0 and format 1 raw cost the same bytes),
  `note_revisions.pending_*` (verbatim copies of `notes.content`), and the
  body of a pre-T3.6 note (`dek_version` 1): its empty AAD has no compression
  policy, so a re-encode would write format 0 again.
  """
  # One chain per user. `:executing` is deliberately NOT a unique state: a job
  # inserts its own successor while still executing, and must not conflict
  # with itself. So `unique` drops a duplicate enqueue (from `run_pass`) while
  # a hop is pending; `superseded?/1` covers the case it cannot, a Lifeline
  # rescue putting a crashed predecessor back to `available` (a state change,
  # not an insert) after its successor was already inserted.
  use Oban.Worker,
    queue: :crypto_backfill,
    priority: 3,
    max_attempts: 5,
    unique: [keys: [:user_id], period: :infinity, states: [:available, :scheduled, :retryable]]

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Backfill.TenantScan
  alias Engram.Crypto
  alias Engram.Crypto.{Envelope, RotationGate, TenantSweep}
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtUpdateLog, Note, VaultIndexState, VaultIndexUpdateLog}
  alias Engram.Repo

  require Logger

  # How long one job works before handing off to its successor, so a rotation
  # queued behind it waits seconds, not minutes.
  @budget_ms 30_000
  @batch_size 200
  # Stored ciphertext bytes per committed chunk (see `reencode_batch/4`).
  # Legacy rows are format 0, so stored is about plaintext size; a chunk peaks
  # near 3x this (ct + plaintext + new ct), well inside the worker's memory.
  @chunk_bytes 8 * 1024 * 1024

  # Processed in this order. `aad` = {AAD table, AAD column, field holding the AAD row id}.
  @columns [
    %{
      label: :notes_content,
      schema: Note,
      key: :id,
      ct: :content_ciphertext,
      nonce: :content_nonce,
      aad: {:notes, :content, :id}
    },
    %{
      label: :notes_crdt_state,
      schema: Note,
      key: :id,
      ct: :crdt_state_ciphertext,
      nonce: :crdt_state_nonce,
      aad: {:notes, :crdt_state, :id}
    },
    %{
      label: :crdt_update_log,
      schema: CrdtUpdateLog,
      key: :id,
      ct: :update_ciphertext,
      nonce: :update_nonce,
      aad: {:notes, :crdt_state, :note_id}
    },
    %{
      label: :vault_index_states,
      schema: VaultIndexState,
      key: :vault_id,
      ct: :state_ciphertext,
      nonce: :state_nonce,
      aad: {:vault_index_states, :state, :vault_id}
    },
    %{
      label: :vault_index_update_log,
      schema: VaultIndexUpdateLog,
      key: :id,
      ct: :update_ciphertext,
      nonce: :update_nonce,
      aad: {:vault_index_update_log, :update, :id}
    }
  ]

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id} = args} = job) when is_binary(user_id) do
    cond do
      not Envelope.compression_on?() ->
        {:cancel, :compression_off}

      superseded?(job) ->
        {:cancel, :superseded}

      true ->
        run(user_id, args)
    end
  end

  defp run(user_id, args) do
    deadline = System.monotonic_time(:millisecond) + setting(:budget_ms, @budget_ms)
    start = args["column"] || "notes_content"
    columns = Enum.drop_while(@columns, &(Atom.to_string(&1.label) != start))
    run_columns(user_id, columns, args["after"], deadline)
  end

  # A newer in-flight job for this user exists: this one is a rescued
  # predecessor whose successor already took over the chain.
  defp superseded?(%Oban.Job{id: id, args: %{"user_id" => user_id}}) when is_integer(id) do
    worker = inspect(__MODULE__)

    Repo.exists?(
      from(j in Oban.Job,
        where: j.worker == ^worker and j.id > ^id,
        where: j.state in ~w(available scheduled executing retryable),
        where: fragment("?->>'user_id' = ?", j.args, ^user_id)
      )
    )
  end

  defp superseded?(_job), do: false

  defp run_columns(_user_id, [], _after, _deadline), do: :ok

  defp run_columns(user_id, [column | rest], after_id, deadline) do
    case TenantSweep.each_batch(
           user_id,
           column.schema,
           &reencode_batch(user_id, column, &1, deadline),
           after: after_id,
           batch_size: setting(:batch_size, @batch_size),
           fun_in_tenant: false
         ) do
      :ok -> run_columns(user_id, rest, nil, deadline)
      {:halt, last_id} -> hand_off(user_id, column.label, last_id)
      {:error, :rotation_in_progress} -> {:snooze, 60}
      {:error, :user_not_found} -> {:cancel, :user_not_found}
      {:error, _} = err -> err
    end
  end

  defp hand_off(user_id, name, last_id) do
    case Oban.insert(
           new(%{"user_id" => user_id, "column" => Atom.to_string(name), "after" => last_id})
         ) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  # Test seam: tests shrink the budget and batch size through app env.
  defp setting(key, default),
    do: :engram |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)

  @doc """
  Enqueues one job per user with a legacy row; returns how many. Discovery
  runs inside each user's tenant context (`TenantScan`, #1349).
  """
  @spec enqueue_missing() :: non_neg_integer()
  # ponytail: per user, one EXISTS per column whose `octet_length` predicates
  # no index serves, so a pass scans every row of every user (runner: hourly
  # while open, daily re-verify after). Fine at today's row counts; if
  # crdt_update_log grows, add a partial index on (user_id) WHERE
  # octet_length(update_nonce) = 12 (and likewise per column).
  def enqueue_missing do
    user_ids = TenantScan.flat_map_users(fn uid -> if any_legacy?(uid), do: [uid], else: [] end)
    # One insert per user, not insert_all: Oban's Basic engine ignores
    # `unique` in insert_all.
    Enum.each(user_ids, fn uid -> {:ok, _} = Oban.insert(new(%{"user_id" => uid})) end)
    length(user_ids)
  end

  @doc "True while the user still has a row this worker would re-encode."
  @spec legacy_rows?(Ecto.UUID.t()) :: boolean()
  def legacy_rows?(user_id) do
    {:ok, any} = Repo.with_tenant(user_id, fn -> any_legacy?(user_id) end)
    any
  end

  defp any_legacy?(user_id),
    do: Enum.any?(@columns, &Repo.exists?(where(legacy(&1), [r], r.user_id == ^user_id)))

  # The done predicate and the worker's selection, one definition. A 16-byte
  # ciphertext is the tag alone (empty plaintext, format 0 by design); a
  # 13-byte nonce is format 1, done whatever its codec.
  defp legacy(%{label: name, schema: schema, ct: ct, nonce: nonce}) do
    from(r in schema,
      where: fragment("octet_length(?) = 12", field(r, ^nonce)),
      where: fragment("octet_length(?) > 16", field(r, ^ct))
    )
    |> body_with_bound_aad(name)
  end

  defp body_with_bound_aad(query, :notes_content),
    do: where(query, [n], n.dek_version >= ^Crypto.row_version_aad_bound())

  defp body_with_bound_aad(query, _name), do: query

  # Per sweep batch: probe the stored size of each legacy row, cut the batch
  # into chunks of at most `@chunk_bytes` stored bytes (always at least one
  # row, so a single huge row still progresses: notes have no size cap), and
  # commit each chunk in its own tenant transaction. Bounds both the memory
  # one chunk holds (about ct + plaintext + new ct) and how long its row
  # locks are held.
  defp reencode_batch(user_id, column, ids, deadline) do
    :telemetry.execute([:engram, :reencode_envelopes, :batch], %{count: length(ids)}, %{
      column: column.label
    })

    user_id
    |> Repo.with_tenant!(fn -> stored_sizes(column, ids) end)
    |> chunk_by_bytes(setting(:chunk_bytes, @chunk_bytes))
    |> reencode_chunks(user_id, column, deadline, List.last(ids))
  end

  # `octet_length` reads the varlena header (no detoast) and is the
  # uncompressed size, which is what a chunk costs in memory.
  defp stored_sizes(%{key: key, ct: ct} = column, ids) do
    column
    |> legacy()
    |> where([r], field(r, ^key) in ^ids)
    |> order_by([r], field(r, ^key))
    |> select([r], {field(r, ^key), fragment("octet_length(?)", field(r, ^ct))})
    |> Repo.all()
  end

  @doc false
  # Splits `[{id, bytes}]` into chunks of ids whose bytes sum to at most
  # `budget`. A row alone over the budget is its own chunk. Public for tests.
  def chunk_by_bytes(sizes, budget) do
    sizes
    |> Enum.chunk_while(
      {[], 0},
      fn {id, bytes}, {acc, total} ->
        if acc != [] and total + bytes > budget,
          do: {:cont, Enum.reverse(acc), {[id], bytes}},
          else: {:cont, {[id | acc], total + bytes}}
      end,
      fn
        {[], _} -> {:cont, {[], 0}}
        {acc, _} -> {:cont, Enum.reverse(acc), {[], 0}}
      end
    )
  end

  defp reencode_chunks([], _user_id, _column, deadline, last_id),
    do: deadline_check(deadline, last_id)

  defp reencode_chunks([chunk | rest], user_id, column, deadline, last_id) do
    with :ok <- reencode_chunk(user_id, column, chunk) do
      cond do
        rest == [] -> deadline_check(deadline, last_id)
        past?(deadline) -> {:halt, List.last(chunk)}
        true -> reencode_chunks(rest, user_id, column, deadline, last_id)
      end
    end
  end

  defp deadline_check(deadline, last_id), do: if(past?(deadline), do: {:halt, last_id}, else: :ok)

  defp past?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  # One transaction per chunk. The DEK and rotation gate are re-checked per
  # chunk: a rotation that started (or finished) since the last one must stop
  # this, and a finished one changes the DEK.
  defp reencode_chunk(
         user_id,
         %{key: key, ct: ct, nonce: nonce, aad: {_t, _c, aad_id}} = column,
         ids
       ) do
    result =
      Repo.with_tenant!(user_id, fn ->
        with {:ok, dek} <- current_dek(user_id) do
          column
          |> legacy()
          |> where([r], field(r, ^key) in ^ids)
          |> select([r], %{
            id: field(r, ^key),
            aad_id: field(r, ^aad_id),
            ct: field(r, ^ct),
            nonce: field(r, ^nonce)
          })
          |> Repo.all()
          |> Enum.each(&reencode_row(column, &1, dek))
        end
      end)

    # After the commit, so a handler sees the chunk's transaction closed.
    if result == :ok,
      do:
        :telemetry.execute([:engram, :reencode_envelopes, :chunk], %{count: length(ids)}, %{
          column: column.label
        })

    result
  end

  defp current_dek(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :user_not_found}
      user -> with :ok <- RotationGate.check_user(user), do: Crypto.get_dek(user)
    end
  end

  defp reencode_row(
         %{label: name, aad: {table, col, _}},
         %{id: id, ct: ct, nonce: nonce} = row,
         dek
       ) do
    aad = Crypto.aad_for_row(table, col, row.aad_id)

    case Envelope.decrypt(ct, nonce, dek, aad) do
      {:ok, plaintext} ->
        {new_ct, new_nonce} = Envelope.encrypt(plaintext, dek, aad)
        write_row(name, id, ct, new_ct, new_nonce)

      :error ->
        Logger.warning(
          "envelope re-encode: row does not decrypt, left as is",
          Metadata.with_category(:warning, :crypto, table: name, row_id: id)
        )
    end
  end

  @doc false
  # The CAS write. Public as the seam for the stale-read test. Must run in
  # the user's tenant context. A miss (0 rows) means the row changed since it
  # was read; it is left for the next pass. The CAS is a byte-for-byte bytea
  # comparison, so the OLD ciphertext travels back to Postgres as a query
  # parameter: each write sends about twice the row's stored bytes, cheap next
  # to the decrypt + seal.
  def write_row(name, id, old_ct, new_ct, new_nonce) do
    %{schema: schema, key: key, ct: ct, nonce: nonce} = Enum.find(@columns, &(&1.label == name))

    from(r in schema, where: field(r, ^key) == ^id and field(r, ^ct) == ^old_ct)
    |> Repo.update_all(set: [{ct, new_ct}, {nonce, new_nonce}])
  end
end
