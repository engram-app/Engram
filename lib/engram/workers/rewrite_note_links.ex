defmodule Engram.Workers.RewriteNoteLinks do
  @moduledoc """
  Oban worker: rewrite `[[wikilink]]`/`![[embed]]` occurrences in every
  note referring to a just-renamed note/attachment (issues #648/#1231,
  Phase 1). Enqueued by `Notes.rename_note/4` and
  `Attachments.move_attachment/4` — REST/MCP origins only; plugin-origin
  renames are rewritten by Obsidian itself and never reach these
  functions, preserving the exactly-one-rewriter invariant.

  Chunked cursor chain over distinct source notes (batch #{100}), keyed on
  the OLD basename hmac of `note_links.target_basename_hmac` — stable
  under the concurrent `RebindNoteLinks` jobs the same rename enqueues.
  Per-source-note error isolation: one failing note logs (ids only) +
  counts `[:engram, :links, :rewrite, :failed]` and the rest proceed.
  A rewrite failure never fails or rolls back the rename.

  Args carry ids + base64 HMACs only (T3.2/H3 — plaintext in
  `oban_jobs.args` JSONB defeats at-rest encryption). The old plaintext
  path is recovered at run time by decrypting the rename tombstone (the
  soft-deleted row both rename paths insert at the old path).
  """

  # No `unique`: a cursor worker re-enqueues its own successor mid-run,
  # which collides with `:incomplete` uniqueness (the running job counts as
  # an in-flight match) and would silently drop the successor, killing the
  # loop after one batch — see Engram.Workers.BackfillNoteLinks. Idempotence
  # comes from the rewrite itself: already-rewritten occurrences plan no
  # edits, so a duplicate job converges as a no-op pass.
  use Oban.Worker, queue: :indexing, max_attempts: 3

  import Ecto.Query

  alias Engram.Attachments.Attachment
  alias Engram.Crypto
  alias Engram.Crypto.RotationGate
  alias Engram.Links.Rewriter
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults

  require Logger

  @default_batch_size 100
  @start_cursor "00000000-0000-0000-0000-000000000000"

  @doc """
  Build a rewrite job. `old_path_hmac_b64`/`old_basename_hmac_b64` are
  ALREADY base64 — every enqueue site computes them from plaintext it has
  in scope (T3.2: only the opaque encodings enter `oban_jobs.args`).
  """
  @spec new_for(binary(), binary(), :note | :attachment, binary(), String.t(), String.t()) ::
          Ecto.Changeset.t()
  def new_for(user_id, vault_id, kind, target_id, old_path_hmac_b64, old_basename_hmac_b64) do
    new(%{
      "user_id" => user_id,
      "vault_id" => vault_id,
      "target_kind" => Atom.to_string(kind),
      "target_id" => target_id,
      "old_path_hmac" => old_path_hmac_b64,
      "old_basename_hmac" => old_basename_hmac_b64,
      "cursor" => @start_cursor
    })
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case RotationGate.check(args["user_id"]) do
      {:error, :rotation_in_progress} -> {:snooze, 60}
      {:error, :user_not_found} -> {:discard, :user_deleted}
      :ok -> run(args)
    end
  end

  defp run(args) do
    %{
      "user_id" => user_id,
      "vault_id" => vault_id,
      "target_kind" => kind_s,
      "target_id" => target_id,
      "old_path_hmac" => old_path_hmac_b64,
      "old_basename_hmac" => old_basename_hmac_b64
    } = args

    cursor = args["cursor"] || @start_cursor
    batch_size = args["batch_size"] || @default_batch_size
    kind = kind_from(kind_s)

    with {:ok, old_path_hmac} <- decode_b64(old_path_hmac_b64),
         {:ok, old_basename_hmac} <- decode_b64(old_basename_hmac_b64),
         {:ok, user} <- load_user(user_id),
         {:ok, vault} <- load_vault(user, vault_id),
         {:ok, old_path} <- tombstone_old_path(user, vault, kind, old_path_hmac),
         {:ok, target} <- build_target(user, vault, kind, target_id, old_path) do
      ids = Rewriter.source_note_ids(user, vault, old_basename_hmac, cursor, batch_size)
      rewrite_each(user, vault, ids, target)

      if length(ids) == batch_size do
        args
        |> Map.put("cursor", List.last(ids))
        |> new()
        |> Oban.insert()
        |> case do
          {:ok, _job} -> :ok
          {:error, reason} -> {:error, reason}
        end
      else
        :ok
      end
    end
  end

  defp kind_from("attachment"), do: :attachment
  defp kind_from(_), do: :note

  defp decode_b64(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:discard, :invalid_hmac_base64}
    end
  end

  defp load_user(user_id) do
    case Repo.get(Engram.Accounts.User, user_id) do
      nil -> {:discard, :user_deleted}
      user -> {:ok, user}
    end
  end

  defp load_vault(user, vault_id) do
    case Vaults.get_vault(user, vault_id) do
      {:ok, vault} -> {:ok, vault}
      {:error, :not_found} -> {:discard, :vault_deleted}
    end
  end

  defp build_target(user, vault, kind, target_id, old_path) do
    case Rewriter.build_target(user, vault, kind, target_id, old_path) do
      {:ok, target} -> {:ok, target}
      # Renamed row deleted (or renamed again and gone) before we ran —
      # nothing coherent to rewrite toward; a later rename enqueues its own job.
      {:error, :target_gone} -> {:discard, :target_gone}
    end
  end

  # The rename tombstone at the OLD path carries the plaintext we must not
  # put in args: decrypt it. Newest tombstone wins (repeated renames
  # through the same path).
  defp tombstone_old_path(user, vault, :note, old_path_hmac) do
    Repo.one(
      from(n in Note,
        where:
          n.user_id == ^user.id and n.vault_id == ^vault.id and n.kind == "note" and
            n.path_hmac == ^old_path_hmac and not is_nil(n.deleted_at),
        order_by: [desc: n.seq],
        limit: 1
      ),
      skip_tenant_check: true
    )
    |> decrypt_tombstone_path(user, &Crypto.maybe_decrypt_note_fields/2)
  end

  defp tombstone_old_path(user, vault, :attachment, old_path_hmac) do
    Repo.one(
      from(a in Attachment,
        where:
          a.user_id == ^user.id and a.vault_id == ^vault.id and
            a.path_hmac == ^old_path_hmac and not is_nil(a.deleted_at),
        order_by: [desc: a.seq],
        limit: 1
      ),
      skip_tenant_check: true
    )
    |> decrypt_tombstone_path(user, &Crypto.maybe_decrypt_attachment_fields/2)
  end

  defp decrypt_tombstone_path(nil, _user, _decrypt), do: {:discard, :old_path_unrecoverable}

  defp decrypt_tombstone_path(row, user, decrypt) do
    case decrypt.(row, user) do
      {:ok, decrypted} when is_binary(decrypted.path) -> {:ok, decrypted.path}
      _ -> {:discard, :old_path_unrecoverable}
    end
  end

  defp rewrite_each(user, vault, ids, target) do
    Enum.each(ids, fn source_id ->
      result =
        try do
          Rewriter.rewrite_source_note(user, vault, source_id, target)
        rescue
          e -> {:error, e}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      case result do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          kind = Engram.Telemetry.error_kind(reason)

          Logger.warning(
            "link rewrite failed for source note",
            Metadata.with_category(:warning, :sync,
              note_id: source_id,
              target_id: target.id,
              reason: inspect(kind)
            )
          )

          :telemetry.execute([:engram, :links, :rewrite, :failed], %{count: 1}, %{reason: kind})
      end
    end)
  end
end
