defmodule Engram.Workers.BackfillContentHashHmac do
  @moduledoc """
  Phase A — content_hash MD5 → HMAC-SHA256 backfill.

  Walks notes (and attachments) for one (user, vault) pair, recomputes
  `content_hash` with the per-user HKDF-derived content-hash key, and writes
  the new 64-char hex digest in place. Cursor-driven, batched, re-enqueues
  itself until the batch is shorter than `@batch_size`.

  Invoked per-scope: `"scope" => "notes" | "attachments"`. The mix task
  `mix engram.content_hash_hmac` enqueues both scopes for every (user, vault)
  pair that has rows.

  Idempotent: filters on `length(content_hash) = 32` (legacy MD5 hex) so a
  retry after a partial-success batch does not re-rewrite already-rehashed
  rows. embed_hash is also rewritten in lock-step ONLY when the row was
  fully embedded (`embed_hash == content_hash`), to avoid spurious
  re-embedding of unchanged content.
  """

  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 5,
    unique: [keys: [:user_id, :vault_id, :scope], states: [:available, :scheduled]]

  import Ecto.Query
  require Logger

  alias Engram.Accounts.User
  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Crypto.RotationGate
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Storage

  @batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    user_id = args["user_id"]
    vault_id = args["vault_id"]
    cursor = args["cursor"] || 0
    scope = args["scope"] || "notes"

    # T3.7 — gate DEK-accessing work during per-user rotation. The user_id
    # is available directly in args so we can check before acquiring a
    # tenant connection.
    case RotationGate.check(user_id) do
      {:error, :rotation_in_progress} ->
        :telemetry.execute(
          [:engram, :crypto, :rotate, :dek, :gate_blocked],
          %{count: 1},
          %{gate_path: :worker, op: :backfill_content_hash_hmac}
        )

        {:snooze, 60}

      {:error, :user_not_found} ->
        {:discard, :user_deleted}

      :ok ->
        run_backfill(user_id, vault_id, cursor, scope)
    end
  end

  defp run_backfill(user_id, vault_id, cursor, scope) do
    Repo.with_tenant(user_id, fn ->
      with {:ok, user} <- load_user(user_id),
           {:ok, content_key} <- Crypto.dek_content_hash_key(user) do
        case process_batch(scope, user, content_key, vault_id, cursor) do
          {:done, _last} ->
            :ok

          {:more, last_id} ->
            __MODULE__.new(%{
              "user_id" => user_id,
              "vault_id" => vault_id,
              "cursor" => last_id,
              "scope" => scope
            })
            |> Oban.insert()
        end
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _} = err -> err
    end
  end

  defp load_user(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp process_batch("notes", user, content_key, vault_id, cursor) do
    notes =
      from(n in Note,
        where: n.vault_id == ^vault_id,
        where: n.id > ^cursor,
        where: not is_nil(n.content_hash),
        where: fragment("length(?) = 32", n.content_hash),
        order_by: [asc: n.id],
        limit: @batch_size
      )
      |> Repo.all()

    case notes do
      [] ->
        {:done, cursor}

      _ ->
        Enum.each(notes, fn note ->
          rehash_note(note, user, content_key)
        end)

        last_id = notes |> List.last() |> Map.fetch!(:id)

        if length(notes) == @batch_size do
          {:more, last_id}
        else
          {:done, last_id}
        end
    end
  end

  defp process_batch("attachments", user, content_key, vault_id, cursor) do
    attachments =
      from(a in Attachment,
        where: a.vault_id == ^vault_id,
        where: a.id > ^cursor,
        where: not is_nil(a.content_hash),
        where: fragment("length(?) = 32", a.content_hash),
        order_by: [asc: a.id],
        limit: @batch_size
      )
      |> Repo.all()

    case attachments do
      [] ->
        {:done, cursor}

      _ ->
        Enum.each(attachments, fn att ->
          rehash_attachment(att, user, content_key)
        end)

        last_id = attachments |> List.last() |> Map.fetch!(:id)

        if length(attachments) == @batch_size do
          {:more, last_id}
        else
          {:done, last_id}
        end
    end
  end

  defp rehash_note(note, user, content_key) do
    case Crypto.maybe_decrypt_note_fields(note, user) do
      {:ok, decrypted} ->
        new_hash = Crypto.hmac_content_hash(content_key, decrypted.content || "")

        set =
          if note.embed_hash == note.content_hash and not is_nil(note.embed_hash) do
            [content_hash: new_hash, embed_hash: new_hash]
          else
            [content_hash: new_hash]
          end

        from(n in Note, where: n.id == ^note.id)
        |> Repo.update_all(set: set)

      {:error, reason} ->
        emit_skip_telemetry(:note, note, reason)

        Logger.error(
          "BackfillContentHashHmac: skipping note #{note.id} (#{inspect(reason)})"
        )
    end
  end

  defp rehash_attachment(att, user, content_key) do
    aad =
      if is_integer(att.dek_version) and att.dek_version >= 2,
        do: Crypto.aad_for_row(:attachments, :content, att.id),
        else: <<>>

    with {:ok, ciphertext} <- Storage.adapter().get(att.storage_key),
         {:ok, dek} <- Crypto.get_dek(user),
         {:ok, plaintext} <- Envelope.decrypt(ciphertext, att.content_nonce, dek, aad) do
      new_hash = Crypto.hmac_content_hash(content_key, plaintext)

      from(a in Attachment, where: a.id == ^att.id)
      |> Repo.update_all(set: [content_hash: new_hash])
    else
      err ->
        emit_skip_telemetry(:attachment, att, err)

        Logger.error(
          "BackfillContentHashHmac: skipping attachment #{att.id} (#{inspect(err)})"
        )
    end
  end

  defp emit_skip_telemetry(scope, row, reason) do
    :telemetry.execute(
      [:engram, :backfill, :content_hash_skipped],
      %{count: 1},
      %{
        scope: scope,
        id: row.id,
        user_id: row.user_id,
        vault_id: row.vault_id,
        reason: inspect(reason)
      }
    )
  end
end
