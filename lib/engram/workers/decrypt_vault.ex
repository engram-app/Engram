defmodule Engram.Workers.DecryptVault do
  @moduledoc """
  Restores plaintext for every note in a vault. Runs 24h after
  request_decrypt_vault/2, unless cancelled. Same batch/cursor/idempotency
  shape as EncryptVault. Order: Postgres decrypt first (so we have plaintext
  in hand), then Qdrant re-index with plaintext payload.
  """

  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 5,
    unique: [keys: [:vault_id], states: [:available, :scheduled, :executing]]

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
    Repo.with_tenant(user_id, fn ->
      vault = Repo.get!(Vault, vault_id)
      user = Repo.get!(User, user_id)

      case vault.encryption_status do
        "encrypted" ->
          Logger.info("DecryptVault cancelled: vault #{vault_id} back to encrypted")
          :ok

        status when status in ["decrypt_pending", "decrypting"] ->
          {:ok, vault} = ensure_decrypting(vault)
          process_batch(vault, user, cursor)

        other ->
          Logger.error("DecryptVault impossible state: vault #{vault_id} status=#{other}")
          {:error, :bad_status}
      end
    end)
    |> case do
      {:ok, result} -> result
      other -> other
    end
  end

  defp ensure_decrypting(%Vault{encryption_status: "decrypting"} = v), do: {:ok, v}

  defp ensure_decrypting(vault) do
    locked = Repo.get!(Vault, vault.id, lock: "FOR UPDATE")

    updated =
      locked
      |> Ecto.Changeset.change(%{encryption_status: "decrypting"})
      |> Repo.update!()

    {:ok, updated}
  end

  defp process_batch(vault, user, cursor) do
    notes =
      from(n in Note,
        where: n.vault_id == ^vault.id and n.id > ^cursor,
        order_by: [asc: n.id],
        limit: @batch_size
      )
      |> Repo.all()

    case Enum.reduce_while(notes, {:ok, cursor}, &decrypt_note(&1, &2, user, vault)) do
      {:ok, last_id} ->
        if length(notes) == @batch_size do
          {:ok, _} =
            __MODULE__.new(%{
              vault_id: vault.id,
              user_id: user.id,
              cursor: last_id
            })
            |> Oban.insert()

          :ok
        else
          finalize_vault(vault)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decrypt_note(%Note{} = note, {:ok, _last}, user, vault) do
    with {:ok, plain_note} <- decrypt_postgres(note, user),
         :ok <- reindex_plaintext(plain_note, vault) do
      :telemetry.execute(
        [:engram, :crypto, :backfill, :note_decrypted],
        %{},
        %{vault_id: vault.id, note_id: note.id}
      )

      {:cont, {:ok, note.id}}
    else
      error ->
        Logger.error("DecryptVault failed note #{note.id}: #{inspect(error)}")
        {:halt, error}
    end
  end

  defp decrypt_postgres(%Note{} = note, user) do
    with {:ok, decrypted} <- Crypto.maybe_decrypt_note_fields(note, user) do
      note
      |> Note.encryption_changeset(%{
        content: decrypted.content,
        title: decrypted.title,
        tags: decrypted.tags,
        content_ciphertext: nil,
        content_nonce: nil,
        title_ciphertext: nil,
        title_nonce: nil,
        tags_ciphertext: nil,
        tags_nonce: nil
      })
      |> Repo.update()
    end
  end

  defp reindex_plaintext(%Note{} = note, vault) do
    # Re-index with vault.encrypted=false so the payload is plaintext.
    plaintext_vault = %{vault | encrypted: false}

    case Engram.Indexing.index_note(note, plaintext_vault) do
      {:ok, _} -> :ok
      :ok -> :ok
      error -> error
    end
  end

  defp finalize_vault(vault) do
    locked = Repo.get!(Vault, vault.id, lock: "FOR UPDATE")

    if locked.encryption_status == "decrypting" do
      locked
      |> Ecto.Changeset.change(%{
        encrypted: false,
        encryption_status: "none",
        encrypted_at: nil
      })
      |> Repo.update!()
    end

    :telemetry.execute(
      [:engram, :crypto, :backfill, :vault_decrypted],
      %{},
      %{vault_id: vault.id}
    )

    :ok
  end
end
