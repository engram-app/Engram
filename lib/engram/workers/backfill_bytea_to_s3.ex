defmodule Engram.Workers.BackfillByteaToS3 do
  @moduledoc """
  Backfills legacy plaintext-BYTEA attachments into encrypted S3 objects.

  Idempotent: rows with encryption_version=1 are skipped. Cursor-driven
  batches keep memory bounded. The BYTEA `content` column is intentionally
  left in place — a follow-up PR nulls it out after a deploy cycle.
  """
  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 5,
    # Intentionally excludes `executing` — the worker re-enqueues itself for
    # the next batch from inside `perform/1`, where its own job is still in the
    # `executing` state. Including `executing` causes Oban to flag the
    # self-reenqueue as a duplicate, silently dropping the next batch.
    unique: [keys: [:user_id, :vault_id], states: [:available, :scheduled]]

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Repo
  alias Engram.Storage

  @batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id, "cursor" => cursor}}) do
    with {:ok, user} <- load_user(user_id),
         {:ok, user} <- Crypto.ensure_user_dek(user),
         {:ok, dek} <- Crypto.get_dek(user) do
      rows = legacy_batch(user_id, vault_id, cursor)

      result =
        Enum.reduce_while(rows, :ok, fn att, _acc ->
          case encrypt_one(att, dek) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
        end)

      case result do
        :ok ->
          if length(rows) == @batch_size do
            next_cursor = List.last(rows).id

            __MODULE__.new(%{user_id: user_id, vault_id: vault_id, cursor: next_cursor})
            |> Oban.insert()

            :ok
          else
            :ok
          end

        {:error, _} = err ->
          err
      end
    end
  end

  defp load_user(user_id) do
    case Accounts.get_user(user_id) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp legacy_batch(user_id, vault_id, cursor) do
    Repo.all(
      from(a in Attachment,
        where:
          a.user_id == ^user_id and a.vault_id == ^vault_id and
            a.encryption_version == 0 and not is_nil(a.content) and a.id > ^cursor,
        order_by: [asc: a.id],
        limit: ^@batch_size
      ),
      skip_tenant_check: true
    )
  end

  defp encrypt_one(%Attachment{} = att, dek) do
    {ciphertext, nonce} = Envelope.encrypt(att.content, dek)
    key = att.storage_key || Storage.key(att.user_id, att.vault_id, att.path)

    case Storage.adapter().put(key, ciphertext, content_type: att.mime_type) do
      :ok ->
        {:ok, _} =
          att
          |> Attachment.changeset(%{
            encryption_version: 1,
            content_nonce: nonce,
            storage_key: key
          })
          |> Repo.update(skip_tenant_check: true)

        :ok

      {:error, reason} ->
        {:error, {:storage, reason}}
    end
  end
end
