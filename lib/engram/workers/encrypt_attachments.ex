defmodule Engram.Workers.EncryptAttachments do
  @moduledoc """
  Backfill-encrypts every plaintext attachment in a vault. Mirrors
  `Engram.Workers.EncryptVault`: batch of 100 per job, per-row atomicity,
  cursor-resumable on crash, self-re-enqueues until exhausted. Uses the
  partial index `attachments_legacy_plaintext_idx` (encryption_version=0)
  as the source of work; finalize is a telemetry-only no-op since
  attachments have no vault-level status flag.
  """

  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 5,
    unique: [keys: [:vault_id], states: [:available, :scheduled]]

  import Ecto.Query
  require Logger

  alias Engram.Accounts.User
  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Repo
  alias Engram.Storage
  alias Engram.Vaults.Vault

  @batch_size 100

  @doc """
  Scan every vault holding at least one legacy plaintext attachment
  (`encryption_version = 0`, not soft-deleted) and enqueue one
  `EncryptAttachments` job per vault. Returns `{:ok, enqueued_count}`.

  Skips tenant scoping — the legacy partial index is the source of truth
  and the worker scopes per-vault on dispatch.
  """
  @spec enqueue_legacy_vaults() :: {:ok, non_neg_integer()}
  def enqueue_legacy_vaults do
    pairs =
      from(a in Attachment,
        where: a.encryption_version == 0 and is_nil(a.deleted_at),
        distinct: true,
        select: {a.user_id, a.vault_id}
      )
      |> Repo.all(skip_tenant_check: true)

    Enum.each(pairs, fn {uid, vid} ->
      %{user_id: uid, vault_id: vid, cursor: 0}
      |> __MODULE__.new()
      |> Oban.insert()
    end)

    {:ok, length(pairs)}
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"vault_id" => vault_id, "user_id" => user_id, "cursor" => cursor}}) do
    case load_batch(vault_id, user_id, cursor) do
      :noop -> :ok
      {:error, _} = err -> err
      {:ok, %{vault: vault, atts: []}} -> finalize(vault, 0)
      {:ok, %{user: user, vault: vault, atts: atts}} -> commit_batch(user, vault, atts)
    end
  end

  defp load_batch(vault_id, user_id, cursor) do
    Repo.with_tenant(user_id, fn ->
      vault = Repo.get!(Vault, vault_id)
      user = Repo.get!(User, user_id)

      with {:ok, user} <- Crypto.ensure_user_dek(user) do
        atts =
          from(a in Attachment,
            where:
              a.vault_id == ^vault.id and
                a.encryption_version == 0 and
                a.id > ^cursor and
                is_nil(a.deleted_at),
            order_by: [asc: a.id],
            limit: @batch_size
          )
          |> Repo.all()

        {:ok, %{user: user, vault: vault, atts: atts}}
      end
    end)
    |> unwrap()
  end

  defp commit_batch(user, vault, atts) do
    {:ok, dek} = Crypto.get_dek(user)

    Repo.with_tenant(user.id, fn ->
      Enum.reduce_while(atts, {:ok, 0}, fn att, {:ok, _} ->
        case encrypt_one(att, user, vault, dek) do
          :ok ->
            {:cont, {:ok, att.id}}

          {:error, reason} = err ->
            Logger.error("EncryptAttachments failed att #{att.id}: #{inspect(reason)}")
            {:halt, err}
        end
      end)
    end)
    |> unwrap()
    |> case do
      {:ok, last_id} ->
        if length(atts) == @batch_size,
          do: enqueue_next(vault, user, last_id),
          else: finalize(vault, length(atts))

      err ->
        err
    end
  end

  # BYTEA-backed legacy row — content already in the column.
  defp encrypt_one(%Attachment{content: bytes} = att, _user, _vault, dek) when is_binary(bytes) do
    {ct, nonce} = Envelope.encrypt(bytes, dek)
    update_row(att, %{encryption_version: 1, content_nonce: nonce, content: ct})
  end

  # S3-backed legacy row — fetch, encrypt, rewrite, update row metadata only.
  defp encrypt_one(%Attachment{content: nil, storage_key: key} = att, user, vault, dek) do
    backend = Storage.adapter()
    fetch_key = key || Storage.key(user.id, vault.id, att.path)

    with {:ok, plaintext} <- backend.get(fetch_key),
         {ct, nonce} <- Envelope.encrypt(plaintext, dek),
         :ok <- backend.put(fetch_key, ct, content_type: att.mime_type) do
      update_row(att, %{encryption_version: 1, content_nonce: nonce})
    else
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  defp update_row(att, attrs) do
    case att |> Attachment.changeset(attrs) |> Repo.update() do
      {:ok, _} -> :ok
      err -> err
    end
  end

  defp enqueue_next(vault, user, last_id) do
    case __MODULE__.new(%{vault_id: vault.id, user_id: user.id, cursor: last_id}) |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: false}} ->
        :ok

      {:ok, %Oban.Job{conflict?: true}} ->
        Logger.error(
          "EncryptAttachments next-batch insert conflicted (vault=#{vault.id} cursor=#{last_id}); backfill would stall."
        )

        {:error, :next_batch_conflict}

      {:error, _} = err ->
        err
    end
  end

  defp finalize(vault, count) do
    :telemetry.execute(
      [:engram, :crypto, :attachment_backfill, :vault_done],
      %{processed: count},
      %{vault_id: vault.id}
    )

    :ok
  end

  defp unwrap({:ok, inner}), do: inner
  defp unwrap(other), do: other
end
