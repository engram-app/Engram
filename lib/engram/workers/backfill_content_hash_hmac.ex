defmodule Engram.Workers.BackfillContentHashHmac do
  @moduledoc """
  Phase A — content_hash MD5 → HMAC-SHA256 backfill.

  Walks notes (and attachments) for one (user, vault) pair, recomputes
  `content_hash` with the per-user HKDF-derived content-hash key, and writes
  the new 64-char hex digest in place. Cursor-driven, batched, re-enqueues
  itself until the batch is shorter than the batch size.

  Invoked per-scope: `"scope" => "notes" | "attachments"`. The mix task
  `mix engram.content_hash_hmac` enqueues both scopes for every (user, vault)
  pair that has rows.

  Idempotent: filters on `length(content_hash) = 32` (legacy MD5 hex) so a
  retry after a partial-success batch does not re-rewrite already-rehashed
  rows. embed_hash is also rewritten in lock-step ONLY when the row was
  fully embedded (`embed_hash == content_hash`), to avoid spurious
  re-embedding of unchanged content.
  """

  # No `unique`: a cursor worker re-enqueues its own successor mid-run, which
  # collides with `:incomplete` uniqueness (the still-"executing" job counts as
  # an in-flight match on the same user_id/vault_id/scope, because `cursor` is
  # not a unique key) and Oban's unique-insert silently returns the EXISTING
  # job instead of inserting the successor. The loop then dies after the first
  # batch and every row past @default_batch_size is left un-migrated, with no
  # error anywhere — the insert "succeeds". This is #1230; the same defect was
  # caught pre-merge on Engram.Workers.BackfillNoteLinks, which carries the
  # matching comment.
  #
  # Idempotence comes from the scope filters instead — both scopes select only
  # `length(content_hash) = 32` (legacy MD5 hex), so a re-run after a partial
  # batch skips already-rehashed rows rather than double-hashing them.
  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 5

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Crypto.RotationGate
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Storage

  require Logger

  @default_batch_size 100

  # 60 min, the Lifeline `rescue_after` ceiling. This walks every row it
  # owns, and none of the long queues (crypto_backfill/export/cleanup) is
  # user-facing — a slot held here costs nothing, while a kill mid-rotation
  # costs a lot. Finite is the point, not tight. See #1496.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(60)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    user_id = args["user_id"]
    vault_id = args["vault_id"]
    cursor = normalize_cursor(args["cursor"])
    scope = args["scope"] || "notes"
    # Overridable so the real-dispatch regression test can drive multiple
    # batches without inserting 101 rows. Production never sets it.
    batch_size = args["batch_size"] || @default_batch_size

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
        run_backfill(user_id, vault_id, cursor, scope, batch_size)
    end
  end

  defp run_backfill(user_id, vault_id, cursor, scope, batch_size) do
    Repo.with_tenant(user_id, fn ->
      with {:ok, user} <- load_user(user_id),
           {:ok, content_key} <- Crypto.dek_content_hash_key(user) do
        case process_batch(scope, user, content_key, vault_id, cursor, batch_size) do
          {:done, _last} ->
            :ok

          {:more, last_id} ->
            __MODULE__.new(%{
              "user_id" => user_id,
              "vault_id" => vault_id,
              "cursor" => last_id,
              "scope" => scope,
              "batch_size" => batch_size
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

  # Cursor is a UUID lower-bound for the seek loop. Accept the nil-uuid as
  # the natural "start of table" sentinel; tolerate legacy `0` / nil from
  # callers that haven't been updated post-PG18-UUID rework.
  defp normalize_cursor(nil), do: "00000000-0000-0000-0000-000000000000"
  defp normalize_cursor(0), do: "00000000-0000-0000-0000-000000000000"
  defp normalize_cursor(cursor) when is_binary(cursor), do: cursor

  defp load_user(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp process_batch("notes", user, content_key, vault_id, cursor, batch_size) do
    notes =
      from(n in Note,
        where: n.vault_id == ^vault_id,
        where: n.id > ^cursor,
        where: not is_nil(n.content_hash),
        where: fragment("length(?) = 32", n.content_hash),
        order_by: [asc: n.id],
        limit: ^batch_size
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

        if length(notes) == batch_size do
          {:more, last_id}
        else
          {:done, last_id}
        end
    end
  end

  defp process_batch("attachments", user, content_key, vault_id, cursor, batch_size) do
    attachments =
      from(a in Attachment,
        where: a.vault_id == ^vault_id,
        where: a.id > ^cursor,
        where: not is_nil(a.content_hash),
        where: fragment("length(?) = 32", a.content_hash),
        order_by: [asc: a.id],
        limit: ^batch_size
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

        if length(attachments) == batch_size do
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

        Engram.Logger.DecryptFailure.log(
          "BackfillContentHashHmac: skipping note #{note.id}",
          reason,
          note_id: note.id
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
      # Unwrap {:error, reason} before handing it on, matching rehash_note/3.
      # Passing the whole tuple made `error_kind/1` (which takes elem(0))
      # collapse EVERY attachment failure to :error — a missing blob and a
      # decrypt failure were indistinguishable in telemetry and logs, while
      # the note path reported :not_found vs :decrypt_failed correctly.
      err ->
        reason = unwrap_error(err)
        emit_skip_telemetry(:attachment, att, reason)

        Engram.Logger.DecryptFailure.log(
          "BackfillContentHashHmac: skipping attachment #{att.id}",
          reason,
          attachment_id: att.id
        )
    end
  end

  defp unwrap_error({:error, reason}), do: reason
  # Envelope.decrypt/4 returns a BARE :error, not a tuple. Without this clause
  # the one failure mode that matters most — ciphertext that will not decrypt —
  # still reported error_kind: :error, i.e. the exact collapse this unwrapping
  # exists to remove.
  defp unwrap_error(:error), do: :decrypt_failed
  defp unwrap_error(other), do: other

  defp emit_skip_telemetry(scope, row, reason) do
    :telemetry.execute(
      [:engram, :backfill, :content_hash_skipped],
      %{count: 1},
      %{
        scope: scope,
        id: row.id,
        user_id: row.user_id,
        vault_id: row.vault_id,
        # Bounded atom only — the raw reason can wrap Req/Postgrex terms
        # carrying secrets (same invariant as Engram.Logger.DecryptFailure).
        reason: Engram.Telemetry.error_kind(reason)
      }
    )
  end
end
