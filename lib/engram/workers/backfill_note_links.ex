defmodule Engram.Workers.BackfillNoteLinks do
  @moduledoc """
  Legacy-row backfill for the note-links feature (issue #591).

  Existing rows predate link extraction: their `basename_hmac` is NULL, and
  they carry no `note_links` edges. The embed pipeline only extracts links on
  a content change, so these rows never self-heal. This worker walks each
  (user, vault) pair through three chained scopes, each re-enqueuing the
  next on completion:

    * `"note_hmacs"`       — stamp `basename_hmac` on notes still missing it
    * `"attachment_hmacs"` — same, for attachments
    * `"links"`            — decrypt every live note's content, extract
                              wikilinks/embeds, and persist edges

  Cursor-driven and batched per scope, same shape as
  `Engram.Workers.BackfillContentHashHmac`. Idempotent: the hmac scopes
  filter on `is_nil(basename_hmac)`; the links scope is idempotent by
  construction (`Engram.Links.replace_links/4` is delete+insert).

  Enqueue post-deploy via `Engram.Links.Backfill.enqueue_all/0` (a plain
  function, not `Mix.Task`, so it's release-rpc callable):

      docker exec engram-saas /app/bin/engram rpc 'Engram.Links.Backfill.enqueue_all()'
  """

  use Oban.Worker,
    queue: :crypto_backfill,
    max_attempts: 5,
    unique: [keys: [:user_id, :vault_id, :scope], states: :incomplete]

  import Ecto.Query

  alias Engram.Accounts.User
  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Links
  alias Engram.Links.Parser
  alias Engram.Logger.DecryptFailure
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults

  require Logger

  @default_batch_size 100
  @start_cursor "00000000-0000-0000-0000-000000000000"

  # Config-overridable so a test can exercise the cursor re-enqueue loop
  # without inserting @default_batch_size+1 rows. Prod uses the default.
  defp batch_size,
    do: Application.get_env(:engram, :note_links_backfill_batch_size, @default_batch_size)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    user_id = args["user_id"]
    vault_id = args["vault_id"]
    cursor = normalize_cursor(args["cursor"])
    scope = args["scope"] || "note_hmacs"

    case RotationGate.check(user_id) do
      {:error, :rotation_in_progress} ->
        :telemetry.execute(
          [:engram, :crypto, :rotate, :dek, :gate_blocked],
          %{count: 1},
          %{gate_path: :worker, op: :backfill_note_links}
        )

        {:snooze, 60}

      {:error, :user_not_found} ->
        {:discard, :user_deleted}

      :ok ->
        run_backfill(user_id, vault_id, cursor, scope)
    end
  end

  defp run_backfill(user_id, vault_id, cursor, scope) do
    with {:ok, user} <- load_user(user_id),
         {:ok, vault} <- Vaults.get_vault(user, vault_id) do
      Repo.with_tenant(user_id, fn ->
        {:ok, filter_key} = Crypto.dek_filter_key(user)

        case process_batch(scope, user, vault, filter_key, cursor) do
          {:done, _last} ->
            case next_scope(scope) do
              nil ->
                :ok

              next ->
                __MODULE__.new(%{
                  "user_id" => user_id,
                  "vault_id" => vault_id,
                  "cursor" => @start_cursor,
                  "scope" => next
                })
                |> Oban.insert()
            end

          {:more, last_id} ->
            __MODULE__.new(%{
              "user_id" => user_id,
              "vault_id" => vault_id,
              "cursor" => last_id,
              "scope" => scope
            })
            |> Oban.insert()
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, _} = err -> err
      end
    else
      {:error, :user_not_found} -> {:discard, :user_deleted}
      {:error, :not_found} -> {:discard, :vault_deleted}
    end
  end

  defp next_scope("note_hmacs"), do: "attachment_hmacs"
  defp next_scope("attachment_hmacs"), do: "links"
  defp next_scope("links"), do: nil

  # Cursor is a UUID lower-bound for the seek loop. Accept the nil-uuid as
  # the natural "start of table" sentinel.
  defp normalize_cursor(nil), do: @start_cursor
  defp normalize_cursor(cursor) when is_binary(cursor), do: cursor

  defp load_user(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp process_batch("note_hmacs", user, vault, filter_key, cursor) do
    notes =
      from(n in Note,
        where: n.vault_id == ^vault.id,
        where: n.kind == "note",
        where: n.id > ^cursor,
        where: is_nil(n.basename_hmac),
        where: not is_nil(n.path_ciphertext),
        order_by: [asc: n.id],
        limit: ^batch_size()
      )
      |> Repo.all()

    batch_result(notes, cursor, fn note -> stamp_note_basename_hmac(note, user, filter_key) end)
  end

  defp process_batch("attachment_hmacs", user, vault, filter_key, cursor) do
    attachments =
      from(a in Attachment,
        where: a.vault_id == ^vault.id,
        where: a.id > ^cursor,
        where: is_nil(a.basename_hmac),
        where: not is_nil(a.path_ciphertext),
        order_by: [asc: a.id],
        limit: ^batch_size()
      )
      |> Repo.all()

    batch_result(attachments, cursor, fn att ->
      stamp_attachment_basename_hmac(att, user, filter_key)
    end)
  end

  defp process_batch("links", user, vault, _filter_key, cursor) do
    notes =
      from(n in Note,
        where: n.vault_id == ^vault.id,
        where: n.kind == "note",
        where: is_nil(n.deleted_at),
        where: n.id > ^cursor,
        order_by: [asc: n.id],
        limit: ^batch_size()
      )
      |> Repo.all()

    batch_result(notes, cursor, fn note -> backfill_links_for_note(note, user, vault) end)
  end

  defp batch_result([], cursor, _fun), do: {:done, cursor}

  defp batch_result(rows, _cursor, fun) do
    Enum.each(rows, fun)
    last_id = rows |> List.last() |> Map.fetch!(:id)

    if length(rows) == batch_size() do
      {:more, last_id}
    else
      {:done, last_id}
    end
  end

  defp stamp_note_basename_hmac(note, user, filter_key) do
    case Crypto.maybe_decrypt_note_fields(note, user) do
      {:ok, decrypted} when is_binary(decrypted.path) ->
        hmac = Crypto.hmac_field(filter_key, Links.basename_key(decrypted.path))

        from(n in Note, where: n.id == ^note.id, where: n.kind == "note")
        |> Repo.update_all(set: [basename_hmac: hmac])

      {:ok, _no_path} ->
        :ok

      {:error, reason} ->
        emit_skip_telemetry(:note_hmacs, note, reason)

        DecryptFailure.log(
          "BackfillNoteLinks: skipping note #{note.id} (basename_hmac)",
          reason,
          note_id: note.id
        )
    end
  end

  defp stamp_attachment_basename_hmac(att, user, filter_key) do
    case Crypto.maybe_decrypt_attachment_fields(att, user) do
      {:ok, decrypted} when is_binary(decrypted.path) ->
        hmac = Crypto.hmac_field(filter_key, Links.basename_key(decrypted.path))

        from(a in Attachment, where: a.id == ^att.id)
        |> Repo.update_all(set: [basename_hmac: hmac])

      {:ok, _no_path} ->
        :ok

      {:error, reason} ->
        emit_skip_telemetry(:attachment_hmacs, att, reason)

        DecryptFailure.log(
          "BackfillNoteLinks: skipping attachment #{att.id} (basename_hmac)",
          reason,
          attachment_id: att.id
        )
    end
  end

  defp backfill_links_for_note(note, user, vault) do
    case Crypto.maybe_decrypt_note_fields(note, user) do
      {:ok, decrypted} ->
        parsed = Parser.extract(decrypted.content || "")
        :ok = Links.replace_links(user, vault, note.id, parsed)

      {:error, reason} ->
        emit_skip_telemetry(:links, note, reason)

        DecryptFailure.log(
          "BackfillNoteLinks: skipping note #{note.id} (links)",
          reason,
          note_id: note.id
        )
    end
  end

  defp emit_skip_telemetry(scope, row, reason) do
    :telemetry.execute(
      [:engram, :backfill, :note_links_skipped],
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
