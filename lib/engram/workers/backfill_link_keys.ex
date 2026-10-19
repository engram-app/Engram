defmodule Engram.Workers.BackfillLinkKeys do
  @moduledoc """
  Fills the link resolution keys (`Engram.Links.path_keys/2`,
  `Engram.Links.target_key_hmac/2`) on rows written before they existed, one
  user per chain. Run by the `LinkResolutionKeys` data migration.

  Reads are exact without the keys (they decrypt such rows), so this only
  makes them cheap. Each row is written with a CAS on the ciphertext the key
  was derived from and on the key still being NULL: a rename or a DEK
  rotation in between wins, and the row is left for the writer that changed
  it. A row that never decrypts is logged and left NULL, which keeps the
  migration open (`docs/context/data-migrations-ledger.md`).
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
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    with %User{} = user <- Repo.get(User, user_id),
         :ok <- RotationGate.check_user(user),
         {:ok, dek} <- Crypto.get_dek(user) do
      deadline = System.monotonic_time(:millisecond) + @budget_ms

      if fill(user_id, dek, deadline) == :more,
        do: {:ok, _} = Oban.insert(new(%{"user_id" => user_id}))

      :ok
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

  # The done predicate and the worker's selection, one definition. Notes and
  # attachments without a basename key are never link candidates.
  defp missing(%{schema: NoteLink}), do: from(r in NoteLink, where: is_nil(r.target_key_hmac))

  defp missing(%{schema: schema}) do
    from(r in schema,
      where: not is_nil(r.basename_hmac) and not is_nil(r.path_ciphertext),
      where: is_nil(r.path_ci_hmac) or is_nil(r.path_length)
    )
  end

  defp executing_user_ids do
    from(j in Oban.Job,
      where: j.worker == ^inspect(__MODULE__) and j.state == "executing",
      select: fragment("?->>'user_id'", j.args)
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp fill(user_id, dek, deadline) do
    Enum.reduce_while(@tables, :done, fn table, :done ->
      case fill_table(user_id, table, dek, deadline, nil) do
        :done -> {:cont, :done}
        :more -> {:halt, :more}
      end
    end)
  end

  defp fill_table(user_id, table, dek, deadline, after_id) do
    rows = batch(user_id, table, after_id)

    cond do
      rows == [] ->
        :done

      System.monotonic_time(:millisecond) > deadline ->
        :more

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
        from(r in schema, where: r.id == ^row.id and field(r, ^ct_field) == ^row.ct)
        |> unfilled(schema)
        |> Repo.update_all(set: keys(schema, Crypto.dek_filter_key_from_bytes(dek), plain))

      :error ->
        Logger.warning(
          "link key backfill: row does not decrypt, left unkeyed",
          Metadata.with_category(:warning, :crypto, table: aad_table, row_id: row.id)
        )
    end
  end

  defp unfilled(query, NoteLink), do: where(query, [r], is_nil(r.target_key_hmac))

  defp unfilled(query, _schema),
    do: where(query, [r], is_nil(r.path_ci_hmac) or is_nil(r.path_length))

  defp keys(NoteLink, filter_key, target),
    do: [target_key_hmac: Links.target_key_hmac(filter_key, target)]

  defp keys(_schema, filter_key, path), do: Links.path_keys(filter_key, path)
end
