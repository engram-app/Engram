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

  A row that does not decrypt is logged at `:warning` and left: it keeps the
  migration open and the stuck-migration alert surfaces it.

  Lifeline rescue: if a crashed predecessor is rescued after its successor was
  inserted, the rescued job cancels itself as `:superseded`. The hand-off can
  also hit the unique conflict and insert nothing, so a rescue may leave no
  chain for that user. The next hourly pass re-enqueues it (up to ~1 h delay;
  no work is lost and the migration is never falsely marked done). Per-user
  discovery inserts are not atomic across users either; a partial pass
  self-heals on the next one.

  With the compression kill switch set, a job cancels itself: re-encoding
  would write format 0 again and NULL `crdt_head` for nothing.

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
      not Application.get_env(:engram, :envelope_compression, false) ->
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
           batch_size: setting(:batch_size, @batch_size)
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

  defp reencode_batch(user_id, column, ids, deadline) do
    %{label: name, key: key, ct: ct, nonce: nonce, aad: {_t, _c, aad_id}} = column

    :telemetry.execute([:engram, :reencode_envelopes, :batch], %{count: length(ids)}, %{
      column: name
    })

    # Per batch, not per job: a rotation that started (or finished) since the
    # last batch must stop this one, and a finished one changes the DEK.
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

      if System.monotonic_time(:millisecond) >= deadline, do: {:halt, List.last(ids)}, else: :ok
    end
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
  # was read; it is left for the next pass.
  def write_row(name, id, old_ct, new_ct, new_nonce) do
    %{schema: schema, key: key, ct: ct, nonce: nonce} = Enum.find(@columns, &(&1.label == name))

    from(r in schema, where: field(r, ^key) == ^id and field(r, ^ct) == ^old_ct)
    |> Repo.update_all(set: [{ct, new_ct}, {nonce, new_nonce}])
  end
end
