defmodule Engram.Workers.RewriteNoteLinks do
  @moduledoc """
  Oban worker: rewrite `[[wikilink]]`/`![[embed]]` occurrences in every
  note referring to a just-renamed note/attachment (issues #648/#1231).
  Four enqueue origins: REST/MCP note rename (`Notes.do_rename_note`),
  attachment move (`Attachments.move_attachment/4`), CRDT-origin relocate
  (`Notes.genesis_relocate_live`, gated by `Notes.crdt_rename_rewrites?/1`
  so only non-Obsidian origins — web/MCP — enqueue), and the folder-rename
  cascade (`Notes.do_rename_folder`, one job per moved note). The gating
  rule across all four: plugin/Obsidian-origin renames never enqueue —
  Obsidian's "Automatically update internal links" rewrites those itself,
  preserving the exactly-one-rewriter invariant.

  Chunked cursor chain over distinct source notes (batch #{100}), keyed on
  the OLD basename hmac of `note_links.target_basename_hmac` — stable
  under the concurrent `RebindNoteLinks` jobs the same rename enqueues.
  Per-source-note error isolation: one failing note logs (ids only) +
  counts `[:engram, :links, :rewrite, :failed]` and the rest proceed.
  A rewrite failure never fails or rolls back the rename.

  Args carry ids + base64 HMACs only (T3.2/H3 — plaintext in
  `oban_jobs.args` JSONB defeats at-rest encryption). The old plaintext
  path is recovered at run time from one of two sources: the rename
  tombstone (the soft-deleted row REST/MCP renames insert at the old
  path), or, for CRDT relocates which insert no tombstone, AAD-bound
  ciphertext carried in the job args.
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
  alias Engram.Crypto.Envelope
  alias Engram.Crypto.RotationGate
  alias Engram.Links.Rewriter
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Repo
  alias Engram.Vaults

  require Logger

  @default_batch_size 100
  @start_cursor "00000000-0000-0000-0000-000000000000"

  # The tagged error atoms the rewrite pipeline actually produces
  # (rewrite_source_note/attempt/persist + this worker's own path recovery).
  @failure_reasons [
    :head_advanced,
    :room_gone,
    :target_gone,
    :version_conflict,
    :path_undecryptable,
    :decrypt_failed,
    :old_path_unrecoverable
  ]

  @doc """
  Build a rewrite job. `old_path_hmac_b64`/`old_basename_hmac_b64` are
  ALREADY base64 — every enqueue site computes them from plaintext it has
  in scope (T3.2: only the opaque encodings enter `oban_jobs.args`).
  """
  @spec new_for(
          binary(),
          binary(),
          :note | :attachment,
          binary(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          Ecto.Changeset.t()
  def new_for(
        user_id,
        vault_id,
        kind,
        target_id,
        old_path_hmac_b64,
        old_basename_hmac_b64,
        opts \\ []
      ) do
    base = %{
      "user_id" => user_id,
      "vault_id" => vault_id,
      "target_kind" => Atom.to_string(kind),
      "target_id" => target_id,
      "old_path_hmac" => old_path_hmac_b64,
      "old_basename_hmac" => old_basename_hmac_b64,
      "cursor" => @start_cursor
    }

    args =
      case Keyword.fetch(opts, :old_path_ciphertext) do
        {:ok, ct_b64} ->
          base
          |> Map.put("old_path_ciphertext", ct_b64)
          |> Map.put("old_path_nonce", Keyword.fetch!(opts, :old_path_nonce))

        :error ->
          base
      end

    new(args)
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
         {:ok, old_path} <- recover_old_path(user, vault, kind, old_path_hmac, args),
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

  # Old-path recovery, two sources in order:
  #   1. The REST-rename tombstone at the old path (Phase 1 — do_rename_note_inner
  #      inserts it; decrypt its path field).
  #   2. Phase 2 (CRDT relocate): genesis_relocate_live/move_note repoints the
  #      row IN PLACE — no tombstone exists — so the enqueue site rides the old
  #      path in args as user-DEK AES-GCM ciphertext, AAD-bound to target_id
  #      (T3.2: plaintext never enters oban_jobs.args; the AAD stops replaying
  #      one job's ciphertext onto another). A DEK rotation between enqueue and
  #      run makes the ciphertext undecryptable — that degrades to the same
  #      {:discard, :old_path_unrecoverable} class (rare; any later rename
  #      enqueues its own fresh job).
  defp recover_old_path(user, vault, kind, old_path_hmac, args) do
    case tombstone_old_path(user, vault, kind, old_path_hmac) do
      {:ok, path} -> {:ok, path}
      {:discard, :old_path_unrecoverable} -> args_old_path(user, args)
    end
  end

  defp args_old_path(user, %{
         "old_path_ciphertext" => ct_b64,
         "old_path_nonce" => nonce_b64,
         "target_id" => target_id
       }) do
    with {:ok, ct} <- decode_b64(ct_b64),
         {:ok, nonce} <- decode_b64(nonce_b64),
         {:ok, dek} <- Crypto.get_dek(user),
         aad = Crypto.aad_for_row("oban_rewrite_note_links", "old_path", target_id),
         {:ok, path} <- Envelope.decrypt(ct, nonce, dek, aad) do
      {:ok, path}
    else
      _ -> {:discard, :old_path_unrecoverable}
    end
  end

  defp args_old_path(_user, _args), do: {:discard, :old_path_unrecoverable}

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
          Logger.warning(
            "link rewrite failed for source note",
            Metadata.with_category(:warning, :sync,
              note_id: source_id,
              target_id: target.id,
              # Full error_kind detail (exception module etc.) — logs are
              # not cardinality-bound the way the metric label below is.
              reason: inspect(Engram.Telemetry.error_kind(reason))
            )
          )

          :telemetry.execute([:engram, :links, :rewrite, :failed], %{count: 1}, %{
            reason: telemetry_failure_reason(reason)
          })
      end
    end)
  end

  @doc false
  # This event's :reason becomes a Prometheus label (PromEx.Indexing), whose
  # cardinality contract is "closed enums only". Telemetry.error_kind/1
  # alone maps unknown exceptions to their struct module — an open set — so
  # the emit site buckets here: known pipeline atoms pass through, any
  # exception becomes :exception, everything else :other.
  @spec telemetry_failure_reason(term()) ::
          :decrypt_failed
          | :exception
          | :head_advanced
          | :old_path_unrecoverable
          | :other
          | :path_undecryptable
          | :room_gone
          | :target_gone
          | :version_conflict
  def telemetry_failure_reason(reason) do
    case Engram.Telemetry.error_kind(reason) do
      kind when kind in @failure_reasons -> kind
      _ -> if match?(%{__exception__: true}, reason), do: :exception, else: :other
    end
  end
end
