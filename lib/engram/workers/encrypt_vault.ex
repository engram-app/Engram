defmodule Engram.Workers.EncryptVault do
  @moduledoc """
  Backfill-encrypts every note in a vault. Batch of 100 per job invocation,
  per-note atomicity (Postgres transaction + idempotent Qdrant set_payload),
  cursor-resumable on crash. Re-enqueues itself until the final batch,
  then flips vault status to "encrypted".
  """

  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 5,
    # `executing` is intentionally excluded — the worker re-enqueues itself for
    # the next batch from inside `perform/1`, where its own job is still in the
    # `executing` state. Including `executing` here causes Oban to flag the
    # self-reenqueue as a duplicate (`conflict?: true`), silently swallowing the
    # next-batch insert and stranding the vault in `encrypting` forever. The
    # `available`/`scheduled` window is enough to dedupe rapid user double-toggles.
    unique: [keys: [:vault_id], states: [:available, :scheduled]]

  import Ecto.Query
  require Logger

  alias Engram.Accounts.User
  alias Engram.Crypto
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"vault_id" => vault_id, "user_id" => user_id, "cursor" => cursor}
      }) do
    # 1. Load the batch (short tenant-scoped tx — fast queries only).
    case load_batch(vault_id, user_id, cursor) do
      :noop ->
        :ok

      {:error, _} = err ->
        err

      {:ok, %{vault: vault, notes: []}} ->
        finalize_vault(user_id, vault, 0)

      {:ok, %{vault: vault, user: user, notes: notes}} ->
        # 2. Prepare each note OUTSIDE any transaction. The slow Voyage AI
        # embedding call must not hold a Postgres connection — see the
        # checkout-timeout incident on 2026-04-30.
        case prepare_all(notes, vault, user) do
          {:error, _} = err ->
            err

          {:ok, prepared_list} ->
            # 3. Commit each prepared note in its own short tenant-scoped tx.
            commit_all(user_id, vault, user, prepared_list, notes, cursor)
        end
    end
  end

  defp load_batch(vault_id, user_id, cursor) do
    Repo.with_tenant(user_id, fn ->
      vault = Repo.get!(Vault, vault_id)
      user = Repo.get!(User, user_id)

      cond do
        vault.encryption_status != "encrypting" ->
          Logger.info("EncryptVault no-op: vault #{vault_id} status=#{vault.encryption_status}")
          :noop

        true ->
          with {:ok, user} <- Crypto.ensure_user_dek(user) do
            # Filter out already-encrypted notes so a retry after a partial-success
            # batch (commit succeeded, next-batch enqueue failed → Oban retries
            # with the same cursor) does not re-encrypt empty plaintext over
            # existing ciphertext. Idempotency invariant: a note in this load
            # window has plaintext that has not yet been replaced.
            notes =
              from(n in Note,
                where:
                  n.vault_id == ^vault.id and n.id > ^cursor and is_nil(n.content_ciphertext),
                order_by: [asc: n.id],
                limit: @batch_size
              )
              |> Repo.all()

            {:ok, %{vault: vault, user: user, notes: notes}}
          end
      end
    end)
    |> unwrap_with_tenant()
  end

  defp prepare_all(notes, vault, user) do
    Enum.reduce_while(notes, {:ok, []}, fn note, {:ok, acc} ->
      # Phase B.3: path/folder/tags live only in ciphertext; decrypt before
      # passing into Indexing so Markdown parsing can read note.path.
      with {:ok, decrypted} <- Crypto.maybe_decrypt_note_fields(note, user),
           {:ok, prepared_or_marker} <- Engram.Indexing.prepare_index(decrypted, vault) do
        {:cont, {:ok, [{note, prepared_or_marker} | acc]}}
      else
        {:error, reason} = err ->
          Logger.error("EncryptVault prepare failed note #{note.id}: #{inspect(reason)}")
          {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp commit_all(user_id, vault, user, prepared_list, notes, cursor) do
    Repo.with_tenant(user_id, fn ->
      Enum.reduce_while(prepared_list, {:ok, cursor}, fn {note, prepared}, {:ok, _} ->
        commit_one(note, prepared, user, vault)
      end)
    end)
    |> unwrap_with_tenant()
    |> case do
      {:ok, last_id} ->
        if length(notes) == @batch_size do
          enqueue_next_batch(vault, user, last_id)
        else
          finalize_vault(user_id, vault, length(notes))
        end

      err ->
        err
    end
  end

  defp enqueue_next_batch(vault, user, last_id) do
    case __MODULE__.new(%{vault_id: vault.id, user_id: user.id, cursor: last_id})
         |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: false}} ->
        :ok

      {:ok, %Oban.Job{conflict?: true}} ->
        # Defensive: should not occur given our unique config, but if a future
        # change re-introduces an `executing` overlap we want a loud signal
        # instead of silently stalling the backfill.
        Logger.error(
          "EncryptVault next-batch insert conflicted (vault=#{vault.id} cursor=#{last_id}); vault would stall. Check unique constraint."
        )

        {:error, :next_batch_conflict}

      {:error, _} = err ->
        err
    end
  end

  # Per-note commit — runs inside the caller's `with_tenant/2`.
  # `prepared` is either `:no_chunks` (note had no parseable content) or the
  # `%{chunk_rows, qdrant_points}` map produced by `Indexing.prepare_index/2`.
  defp commit_one(%Note{} = note, prepared, user, vault) do
    started_at = System.monotonic_time()

    with :ok <- commit_qdrant(prepared),
         {:ok, _encrypted_note} <- encrypt_postgres(note, user, vault) do
      duration = System.monotonic_time() - started_at

      :telemetry.execute(
        [:engram, :crypto, :backfill, :note_encrypted],
        %{duration: duration},
        %{vault_id: vault.id, note_id: note.id}
      )

      {:cont, {:ok, note.id}}
    else
      {:error, reason} ->
        Logger.error("EncryptVault failed note #{note.id}: #{inspect(reason)}")
        {:halt, {:error, reason}}
    end
  end

  defp commit_qdrant(:no_chunks), do: :ok

  defp commit_qdrant(prepared) do
    case Engram.Indexing.commit_index(prepared) do
      {:ok, _} -> :ok
      :ok -> :ok
      error -> error
    end
  end

  defp encrypt_postgres(%Note{} = note, user, vault) do
    # Phase B.3: tags are already in `tags_ciphertext` for every row (Phase B
    # contract, written by every upsert). The vault encryption toggle only
    # needs to seal `content` + `title` for previously-unencrypted vaults.
    attrs = %{
      content: note.content || "",
      title: note.title
    }

    case Crypto.maybe_encrypt_note_fields(attrs, user, vault) do
      {:ok, encrypted_attrs} ->
        note
        |> Note.encryption_changeset(encrypted_attrs)
        |> Repo.update()

      error ->
        error
    end
  end

  defp finalize_vault(user_id, vault, processed_count) do
    Repo.with_tenant(user_id, fn ->
      locked = Repo.get!(Vault, vault.id, lock: "FOR UPDATE")

      if locked.encryption_status == "encrypting" do
        locked
        |> Ecto.Changeset.change(%{
          encryption_status: "encrypted",
          encrypted_at: DateTime.utc_now()
        })
        |> Repo.update!()
      end

      :ok
    end)

    :telemetry.execute(
      [:engram, :crypto, :backfill, :vault_encrypted],
      %{processed: processed_count},
      %{vault_id: vault.id}
    )

    :ok
  end

  # `Repo.with_tenant/2` wraps in `Repo.transaction/2`, so the result is
  # always `{:ok, inner}` or `{:error, ...}`. Callers want the inner value.
  defp unwrap_with_tenant({:ok, inner}), do: inner
  defp unwrap_with_tenant(other), do: other
end
