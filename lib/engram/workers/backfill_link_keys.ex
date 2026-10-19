defmodule Engram.Workers.BackfillLinkKeys do
  @moduledoc """
  Fills the link resolution keys (`Engram.Links.path_keys/3`,
  `Engram.Links.target_keys/3`) on rows whose keys are missing or stale
  (written before they existed, by an older release, or under another
  Unicode version), one user per chain. Run by the `LinkResolutionKeys`
  data migration.

  Reads are exact without the keys (they decrypt such rows), so this only
  makes them cheap. Each row is written with a CAS on the ciphertext the key
  was derived from: a rename or a DEK rotation in between wins. A row that
  never decrypts is logged and left unkeyed, which keeps the migration open
  (`docs/context/data-migrations-ledger.md`).
  """
  # One chain per user, as `ReencodeEnvelopes`: `:executing` is not a unique
  # state, so a job can insert its own successor.
  use Oban.Worker,
    queue: :crypto_backfill,
    priority: 3,
    max_attempts: 5,
    unique: [keys: [:user_id], period: :infinity, states: [:available, :scheduled, :retryable]]

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Attachments.Attachment
  alias Engram.Backfill.TenantScan
  alias Engram.Crypto
  alias Engram.Crypto.{Envelope, RotationGate}
  alias Engram.Links
  alias Engram.Links.NoteLink
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Repo

  require Logger

  @budget_ms 30_000
  @batch_size 500

  @tables [
    %{schema: Note, ct: :path_ciphertext, nonce: :path_nonce, aad: {:notes, :path}},
    %{schema: Attachment, ct: :path_ciphertext, nonce: :path_nonce, aad: {:attachments, :path}},
    %{
      schema: NoteLink,
      ct: :target_text_ciphertext,
      nonce: :target_text_nonce,
      aad: {:note_links, :target_text}
    }
  ]

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id} = args}) do
    with %User{} = user <- Repo.get(User, user_id),
         :ok <- RotationGate.check_user(user),
         {:ok, dek} <- Crypto.get_dek(user) do
      deadline = System.monotonic_time(:millisecond) + @budget_ms

      # The successor resumes at the cursor, so rows that never decrypt are
      # walked once per chain, not once per hop.
      case fill(user_id, dek, deadline, args["table"] || 0, args["after"]) do
        :done ->
          :ok

        {:more, table, after_id} ->
          args = %{"user_id" => user_id, "table" => table, "after" => after_id}
          {:ok, _} = Oban.insert(new(args))
          :ok
      end
    else
      nil -> :ok
      {:error, :rotation_in_progress} -> {:snooze, 60}
      {:error, _} = err -> err
    end
  end

  @doc "Enqueues a chain for every user with a row missing its keys. Returns how many."
  @spec enqueue_missing() :: non_neg_integer()
  def enqueue_missing do
    user_ids = TenantScan.flat_map_users(fn uid -> if missing?(uid), do: [uid], else: [] end)
    executing = executing_user_ids()

    # One insert per user: Oban's Basic engine ignores `unique` in insert_all.
    for uid <- user_ids,
        not MapSet.member?(executing, uid),
        do: {:ok, _} = Oban.insert(new(%{"user_id" => uid}))

    length(user_ids)
  end

  defp missing?(user_id),
    do: Enum.any?(@tables, &Repo.exists?(where(missing(&1), [r], r.user_id == ^user_id)))

  # The done predicate and the worker's selection, one definition: keys
  # missing, or stamped for another nonce or Unicode version (the readers'
  # rule in `Engram.Links`). Notes and attachments without a basename key are
  # never link candidates.
  defp missing(%{schema: schema, nonce: nonce}) do
    version = Links.link_keys_version()

    from(r in schema,
      where:
        fragment(
          "? IS DISTINCT FROM (? || ?::bytea)",
          r.link_keys_stamp,
          field(r, ^nonce),
          ^version
        )
    )
    |> candidates_only(schema)
  end

  defp candidates_only(query, NoteLink), do: query

  defp candidates_only(query, _schema),
    do: where(query, [r], not is_nil(r.basename_hmac) and not is_nil(r.path_ciphertext))

  defp executing_user_ids do
    from(j in Oban.Job,
      where: j.worker == ^inspect(__MODULE__) and j.state == "executing",
      select: fragment("?->>'user_id'", j.args)
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # `{:more, table_index, after_id}` when the budget ran out first.
  defp fill(_user_id, _dek, _deadline, index, _after_id) when index >= length(@tables), do: :done

  defp fill(user_id, dek, deadline, index, after_id) do
    case fill_table(user_id, Enum.at(@tables, index), dek, deadline, after_id) do
      :done -> fill(user_id, dek, deadline, index + 1, nil)
      {:more, last_id} -> {:more, index, last_id}
    end
  end

  defp fill_table(user_id, table, dek, deadline, after_id) do
    rows = batch(user_id, table, after_id)

    cond do
      rows == [] ->
        :done

      System.monotonic_time(:millisecond) > deadline ->
        {:more, after_id}

      true ->
        {:ok, _} = Repo.with_tenant(user_id, fn -> Enum.each(rows, &fill_row(&1, table, dek)) end)

        if length(rows) < @batch_size,
          do: :done,
          else: fill_table(user_id, table, dek, deadline, List.last(rows).id)
    end
  end

  defp batch(user_id, %{ct: ct, nonce: nonce} = table, after_id) do
    query =
      from(r in missing(table),
        where: r.user_id == ^user_id,
        order_by: r.id,
        limit: @batch_size,
        select: %{
          id: r.id,
          ct: field(r, ^ct),
          nonce: field(r, ^nonce),
          dek_version: r.dek_version
        }
      )

    query = if after_id, do: where(query, [r], r.id > ^after_id), else: query
    {:ok, rows} = Repo.with_tenant(user_id, fn -> Repo.all(query) end)
    rows
  end

  defp fill_row(row, %{schema: schema, ct: ct_field, aad: {aad_table, aad_column}}, dek) do
    aad =
      if Crypto.aad_bound?(row.dek_version),
        do: Crypto.aad_for_row(aad_table, aad_column, row.id),
        else: <<>>

    case Envelope.decrypt(row.ct, row.nonce, dek, aad) do
      {:ok, plain} ->
        # CAS on the ciphertext the keys come from: a concurrent re-encrypt
        # wins, and its row stays unkeyed for the next pass.
        from(r in schema, where: r.id == ^row.id and field(r, ^ct_field) == ^row.ct)
        |> Repo.update_all(
          set: keys(schema, Crypto.dek_filter_key_from_bytes(dek), plain, row.nonce)
        )

      :error ->
        Logger.warning(
          "link key backfill: row does not decrypt, left unkeyed",
          Metadata.with_category(:warning, :crypto, table: aad_table, row_id: row.id)
        )
    end
  end

  defp keys(NoteLink, filter_key, target, nonce), do: Links.target_keys(filter_key, target, nonce)
  defp keys(_schema, filter_key, path, nonce), do: Links.path_keys(filter_key, path, nonce)
end
