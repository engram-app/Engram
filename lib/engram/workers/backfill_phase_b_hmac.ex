defmodule Engram.Workers.BackfillPhaseBHmac do
  @moduledoc """
  Phase B.1 backfill worker — populates `path_hmac`, `path_ciphertext`,
  `path_nonce`, `folder_hmac`, `folder_ciphertext`, `folder_nonce`,
  `tags_hmac` (notes) and `path_*` (attachments) and `name_*` (vaults)
  for legacy rows that pre-date Phase B.1's dual-write code.

  Cursor-driven per (user, vault). Each invocation processes one batch
  of notes (up to @batch_size) and re-enqueues itself with the next
  cursor until the batch is empty. Attachments + vault are processed
  in full each invocation (small N — saas has ~100 attachments, ~10 vaults).

  Idempotent on retry: skips rows where `path_hmac IS NOT NULL`.

  Pattern mirrors the deleted `Engram.Workers.BackfillByteaToS3` (Phase A.4,
  removed in A.5). See `git show 171ce9e:lib/engram/workers/backfill_bytea_to_s3.ex`.
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
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults.Vault

  @batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "vault_id" => vault_id} = args}) do
    last_id = Map.get(args, "last_id", 0)

    with {:ok, user} <- load_and_prepare_user(user_id),
         {:ok, dek} <- Crypto.get_dek(user),
         {:ok, filter_key} <- Crypto.dek_filter_key(user) do
      {:ok, cursor_result} =
        Repo.with_tenant(user_id, fn ->
          result = backfill_notes(user_id, vault_id, last_id, dek, filter_key)
          backfill_attachments(user_id, vault_id, dek, filter_key)
          backfill_vault(vault_id, dek, filter_key)
          result
        end)

      case cursor_result do
        {:done, _last} ->
          :ok

        {:more, next_cursor} ->
          %{"user_id" => user_id, "vault_id" => vault_id, "last_id" => next_cursor}
          |> __MODULE__.new()
          |> Oban.insert()

          :ok
      end
    end
  end

  # -- private helpers -------------------------------------------------------

  defp load_and_prepare_user(user_id) do
    case Accounts.get_user(user_id) do
      nil -> {:error, :user_not_found}
      user -> Crypto.ensure_user_dek(user)
    end
  end

  defp backfill_notes(user_id, vault_id, last_id, dek, filter_key) do
    notes =
      from(n in Note,
        where: n.user_id == ^user_id and n.vault_id == ^vault_id,
        where: is_nil(n.path_hmac) and n.id > ^last_id,
        order_by: [asc: n.id],
        limit: @batch_size
      )
      |> Repo.all()

    Enum.each(notes, fn note ->
      {path_ct, path_n} = Envelope.encrypt(note.path, dek)
      folder = note.folder || ""
      {folder_ct, folder_n} = Envelope.encrypt(folder, dek)
      tags_hmac = Enum.map(note.tags || [], &Crypto.hmac_field(filter_key, &1))

      Note
      |> where(id: ^note.id)
      |> Repo.update_all(
        set: [
          path_ciphertext: path_ct,
          path_nonce: path_n,
          path_hmac: Crypto.hmac_field(filter_key, note.path),
          folder_ciphertext: folder_ct,
          folder_nonce: folder_n,
          folder_hmac: Crypto.hmac_field(filter_key, folder),
          tags_hmac: tags_hmac
        ]
      )
    end)

    case notes do
      [] -> {:done, last_id}
      _ -> {:more, List.last(notes).id}
    end
  end

  defp backfill_attachments(user_id, vault_id, dek, filter_key) do
    from(a in Attachment,
      where: a.user_id == ^user_id and a.vault_id == ^vault_id,
      where: is_nil(a.path_hmac)
    )
    |> Repo.all()
    |> Enum.each(fn att ->
      {ct, n} = Envelope.encrypt(att.path, dek)

      Attachment
      |> where(id: ^att.id)
      |> Repo.update_all(
        set: [
          path_ciphertext: ct,
          path_nonce: n,
          path_hmac: Crypto.hmac_field(filter_key, att.path)
        ]
      )
    end)
  end

  defp backfill_vault(vault_id, dek, filter_key) do
    case Repo.get(Vault, vault_id) do
      %Vault{name_hmac: nil, name: name} = _vault when is_binary(name) ->
        {ct, n} = Envelope.encrypt(name, dek)

        Vault
        |> where(id: ^vault_id)
        |> Repo.update_all(
          set: [
            name_ciphertext: ct,
            name_nonce: n,
            name_hmac: Crypto.hmac_field(filter_key, name)
          ]
        )

      _ ->
        :noop
    end
  end
end
