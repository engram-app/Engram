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
  this batch's row locks and then rewraps what it wrote (format 1 under the
  old DEK is readable), and any row it already rewrapped fails the CAS.

  A row that does not decrypt is logged at `:warning` and left: it keeps the
  migration open and the stuck-migration alert surfaces it.

  Not re-encoded: attachments (format 0 and format 1 raw cost the same bytes),
  `note_revisions.pending_*` (verbatim copies of `notes.content`), and the
  body of a pre-T3.6 note (`dek_version` 1): its empty AAD has no compression
  policy, so a re-encode would write format 0 again.
  """
  use Oban.Worker, queue: :crypto_backfill, priority: 3, max_attempts: 5

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Backfill.TenantScan
  alias Engram.Crypto
  alias Engram.Crypto.{Envelope, RotationGate, TenantSweep}
  alias Engram.Logger.Metadata
  alias Engram.Notes.{CrdtUpdateLog, Note, VaultIndexState, VaultIndexUpdateLog}
  alias Engram.Repo

  require Logger

  # {name, schema, key, ciphertext column, nonce column}. Same order every pass.
  @columns [
    {:notes_content, Note, :id, :content_ciphertext, :content_nonce},
    {:notes_crdt_state, Note, :id, :crdt_state_ciphertext, :crdt_state_nonce},
    {:crdt_update_log, CrdtUpdateLog, :id, :update_ciphertext, :update_nonce},
    {:vault_index_states, VaultIndexState, :vault_id, :state_ciphertext, :state_nonce},
    {:vault_index_update_log, VaultIndexUpdateLog, :id, :update_ciphertext, :update_nonce}
  ]

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) when is_binary(user_id) do
    Enum.reduce_while(@columns, :ok, fn column, :ok ->
      case TenantSweep.each_batch(user_id, elem(column, 1), &reencode_batch(user_id, column, &1)) do
        :ok -> {:cont, :ok}
        {:error, :rotation_in_progress} -> {:halt, {:snooze, 60}}
        {:error, :user_not_found} -> {:halt, {:cancel, :user_not_found}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Enqueues one job per user with a legacy row; returns how many. Discovery
  runs inside each user's tenant context (`TenantScan`, #1349).
  """
  @spec enqueue_missing() :: non_neg_integer()
  def enqueue_missing do
    user_ids = TenantScan.flat_map_users(fn uid -> if any_legacy?(uid), do: [uid], else: [] end)
    _ = Oban.insert_all(Enum.map(user_ids, &new(%{"user_id" => &1})))
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
  defp legacy({name, schema, _key, ct, nonce}) do
    from(r in schema,
      where: fragment("octet_length(?) = 12", field(r, ^nonce)),
      where: fragment("octet_length(?) > 16", field(r, ^ct))
    )
    |> body_with_bound_aad(name)
  end

  defp body_with_bound_aad(query, :notes_content),
    do: where(query, [n], n.dek_version >= ^Crypto.row_version_aad_bound())

  defp body_with_bound_aad(query, _name), do: query

  defp reencode_batch(user_id, {name, _schema, key, ct, nonce} = column, ids) do
    with {:ok, dek} <- current_dek(user_id) do
      column
      |> legacy()
      |> where([r], field(r, ^key) in ^ids)
      |> select([r], %{id: field(r, ^key), ct: field(r, ^ct), nonce: field(r, ^nonce), row: r})
      |> Repo.all()
      |> Enum.each(&reencode_row(name, &1, dek))
    end
  end

  # Per batch, not per job: a rotation that started (or finished) since the
  # last batch must stop this one, and a finished one changes the DEK.
  defp current_dek(user_id) do
    case Repo.get(User, user_id) do
      nil ->
        {:error, :user_not_found}

      user ->
        with :ok <- RotationGate.check_user(user), do: Crypto.get_dek(user)
    end
  end

  defp reencode_row(name, %{id: id, ct: ct, nonce: nonce, row: row}, dek) do
    aad = aad(name, row)

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

  defp aad(:notes_content, row), do: Crypto.aad_for_row(:notes, :content, row.id)
  defp aad(:notes_crdt_state, row), do: Crypto.aad_for_row(:notes, :crdt_state, row.id)
  defp aad(:crdt_update_log, row), do: Crypto.aad_for_row(:notes, :crdt_state, row.note_id)

  defp aad(:vault_index_states, row),
    do: Crypto.aad_for_row(:vault_index_states, :state, row.vault_id)

  defp aad(:vault_index_update_log, row),
    do: Crypto.aad_for_row(:vault_index_update_log, :update, row.id)

  @doc false
  # The CAS write. Public as the seam for the stale-read test. Must run in
  # the user's tenant context. A miss (0 rows) means the row changed since it
  # was read; it is left for the next pass.
  def write_row(name, id, old_ct, new_ct, new_nonce) do
    {^name, schema, key, ct, nonce} = List.keyfind!(@columns, name, 0)

    from(r in schema, where: field(r, ^key) == ^id and field(r, ^ct) == ^old_ct)
    |> Repo.update_all(set: [{ct, new_ct}, {nonce, new_nonce}])
  end
end
