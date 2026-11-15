defmodule Engram.Workers.RewriteNoteLinks do
  @moduledoc """
  Oban worker: rewrite link occurrences in every note referring to a
  just-renamed note/attachment (issues #648/#1231) — both
  `[[wikilink]]`/`![[embed]]` and markdown `[label](target.md)` syntax
  (#1302), each rewritten back in the form it was written in.
  Five enqueue origins: REST/MCP note rename (`Notes.do_rename_note`),
  attachment move (`Attachments.move_attachment/4`), the two CRDT-origin
  rename legs — live relocate (`Notes.genesis_relocate_live`) and
  resurrect-rename (`Notes.genesis_resurrect`, the same rename arriving for a
  TOMBSTONED row) — both gated by `Notes.crdt_rename_rewrites?/1` so only
  non-Obsidian origins enqueue, and the folder-rename
  cascade (`Notes.do_rename_folder`, ONE chain per folder rename, see
  "Folder chains" below). The gating
  rule across all five: plugin/Obsidian-origin renames never enqueue —
  Obsidian's "Automatically update internal links" rewrites those itself,
  preserving the exactly-one-rewriter invariant.

  Chunked cursor chain over distinct source notes (batch #{100}), keyed on
  the OLD basename hmac of `note_links.target_basename_hmac`, which a
  rename never rewrites.
  Per-source-note error isolation: one failing note logs (ids only) +
  counts `[:engram, :links, :rewrite, :failed]` and the rest proceed.
  A rewrite failure never fails or rolls back the rename.

  Delayed sweep (closes the late-index rewrite window): a source note's
  `[[link]]` is only visible to this worker once async indexing has
  written its `note_links` edge. If a note is created (or edited to add a
  new link) and its target is renamed within that indexing lag (~30s
  observed on staging), the initial walk finds zero sources — the edge
  doesn't exist yet — and completes clean, leaving the late-arriving edge
  permanently dangling with stale text. When a chain's FINAL chunk (this
  module's terminating branch, batch came back short) belongs to a run
  that is not itself a sweep, it enqueues ONE follow-up job: same args,
  cursor reset to the start, `"sweep" => true`, scheduled ~60s out. A
  sweep-marked chain terminates WITHOUT enqueueing another sweep (no
  recursion) — mid-chain successors still preserve the marker so the
  sweep's own chunking doesn't spawn a third pass. This is cheap and safe
  to run unconditionally: the rewrite is idempotent (already-current
  occurrences plan no edits, so a clean run's second walk is a no-op),
  old-path recovery still works on the delayed job (tombstones persist;
  CRDT-origin ciphertext args are carried through verbatim), and there is
  no `unique:` on this worker (see below) so the extra insert can't
  collide with an in-flight chain.

  With the #648 fast path (ExtractNoteLinks, ~2s extraction) and bind-time
  repair (repair_rename_danglers/3) the sweep is a residual backstop for the
  narrow gap where an edge extracts AFTER the walk but BEFORE its own repair
  check could see a matching rename job (clock-skew/queue-latency slivers)
  and for plugin-origin renames (never server-rewritten, so never repaired).
  Re-evaluate shortening/removing it once prod shows
  [:engram, :links, :repair_enqueued] absorbing the late-edge cases and the
  sweep's second walks planning zero edits (rewrite failed=0, sweeps no-op).

  Folder chains (#2523 S5): a folder rename used to queue one chain per
  moved note, so a note path-linking N moved notes was rewritten N times
  (staging, 1k moved notes: 1,000 version bumps on one index note in 8 min,
  1.13 GB of WAL). `new_for_folder/3` queues one chain whose args carry
  every moved note as a `"targets"` entry (the per-note args' three ids/HMACs,
  up to `max_folder_targets/0` per chain). Each page takes the next linking
  notes of ANY moved basename (keyset on `source_note_id`), builds only the
  targets that page's notes name, and rewrites each linking note ONCE with
  every edit: one Y-update, one link rebuild. A target that cannot be built
  (gone, old path unrecoverable) is skipped and counted; the rest proceed.

  Queue `:link_rewrite` (limit 1 per node, worker and single-node only), off
  `:indexing`: a big move waited out other tenants' extraction there. Kill
  switch `:link_rewrite` (`enabled?/0`, a runtime ServiceConfig override):
  off, every job snoozes before any read, nothing is dropped.

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
  # loop after one batch — see git history for the removed note-links backfill. Idempotence
  # comes from the rewrite itself: already-rewritten occurrences plan no
  # edits, so a duplicate job converges as a no-op pass.
  use Oban.Worker, queue: :link_rewrite, max_attempts: 3

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
  @sweep_delay_seconds 60
  # Bounds one chain's args (~130 B a target, copied to every successor) and
  # the targets one page may build. A move past it queues one chain per
  # chunk, so a note linking more moved notes than this is written once a chunk.
  @max_folder_targets 1_000
  # Long, so a paused backlog wakes rarely; short enough that "back on"
  # resumes within minutes (RefreshKeywordVectors' kill switch, copied).
  @paused_snooze 300

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

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @doc "False while the `:link_rewrite` kill switch is off."
  @spec enabled?() :: boolean()
  def enabled?, do: Engram.ServiceConfig.get(:link_rewrite, true) != false

  @doc "Moved notes per folder chain; a bigger move queues one chain per chunk."
  @spec max_folder_targets() :: pos_integer()
  def max_folder_targets, do: @max_folder_targets

  @doc """
  One chain for a folder rename's moved notes. `targets` are
  `{target_id, old_path_hmac_b64, old_basename_hmac_b64}`, at most
  `max_folder_targets/0` (T3.2: ids and HMACs only).
  """
  @spec new_for_folder(binary(), binary(), [{binary(), String.t(), String.t()}]) ::
          Ecto.Changeset.t()
  def new_for_folder(user_id, vault_id, targets) when length(targets) <= @max_folder_targets do
    new(%{
      "user_id" => user_id,
      "vault_id" => vault_id,
      "cursor" => @start_cursor,
      "targets" =>
        Enum.map(targets, fn {id, path_hmac, basename_hmac} ->
          %{"target_id" => id, "old_path_hmac" => path_hmac, "old_basename_hmac" => basename_hmac}
        end)
    })
  end

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
    with :ok <- if(enabled?(), do: :ok, else: {:snooze, @paused_snooze}) do
      case RotationGate.check(args["user_id"]) do
        {:error, :rotation_in_progress} -> {:snooze, 60}
        {:error, :user_not_found} -> {:discard, :user_deleted}
        :ok -> run(args)
      end
    end
  end

  defp run(%{"targets" => entries} = args) do
    cursor = args["cursor"] || @start_cursor
    batch_size = args["batch_size"] || @default_batch_size

    with {:ok, user} <- load_user(args["user_id"]),
         {:ok, vault} <- load_vault(user, args["vault_id"]) do
      by_hmac = Enum.group_by(entries, &Base.decode64!(&1["old_basename_hmac"]))
      hmacs = Map.keys(by_hmac)
      ids = Rewriter.source_note_ids(user, vault, hmacs, cursor, batch_size)
      linked = Rewriter.linked_basenames(user, vault, ids, hmacs)

      targets =
        linked
        |> Enum.map(&elem(&1, 1))
        |> Enum.uniq()
        |> Enum.flat_map(&Map.fetch!(by_hmac, &1))
        |> Enum.flat_map(&folder_target(user, vault, &1))
        |> pre_move_siblings()
        |> Enum.group_by(& &1.old_basename_hmac)

      wanted = Enum.group_by(linked, &elem(&1, 0), &elem(&1, 1))

      ids
      |> Enum.map(fn id ->
        {id, wanted |> Map.get(id, []) |> Enum.flat_map(&Map.get(targets, &1, []))}
      end)
      |> Enum.reject(fn {_id, ts} -> ts == [] end)
      |> then(&rewrite_each(user, vault, &1))

      continue(args, ids, batch_size)
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
      rewrite_each(user, vault, Enum.map(ids, &{&1, target}))
      continue(args, ids, batch_size)
    end
  end

  # A full page re-enqueues the chain at its last id; a short one ends it.
  defp continue(args, ids, batch_size) do
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
      maybe_enqueue_sweep(args)
    end
  end

  # One folder entry to a rewrite target, or nothing: a target that is gone
  # or whose old path cannot be recovered is counted and skipped, so it never
  # stops the rest of the folder's rewrite (the per-note chain discards).
  defp folder_target(user, vault, entry) do
    with {:ok, path_hmac} <- decode_b64(entry["old_path_hmac"]),
         {:ok, old_path} <- recover_old_path(user, vault, :note, path_hmac, entry),
         {:ok, target} <- Rewriter.build_target(user, vault, :note, entry["target_id"], old_path) do
      [target]
    else
      {_, reason} ->
        :telemetry.execute([:engram, :links, :rewrite, :failed], %{count: 1}, %{
          reason: telemetry_failure_reason(reason)
        })

        []
    end
  end

  # Each target's candidate snapshot holds its moved siblings at their NEW
  # paths, but before the move they sat at their old ones. Put them back, so
  # an occurrence resolves to the one sibling it named before the move.
  defp pre_move_siblings(targets) do
    old = Map.new(targets, &{&1.id, &1.old_path})
    back = fn list -> Enum.map(list, fn {id, path} -> {id, Map.get(old, id, path)} end) end

    Enum.map(targets, fn t ->
      Map.update!(t, :pre_rename_candidates, &%{&1 | notes: back.(&1.notes)})
    end)
  end

  # Chain terminated. A plain run schedules one delayed sweep to catch any
  # edge that indexed in after this walk started (see moduledoc). A sweep
  # run terminates quietly — no third pass.
  defp maybe_enqueue_sweep(%{"sweep" => true}), do: :ok

  defp maybe_enqueue_sweep(args) do
    args
    |> Map.put("cursor", @start_cursor)
    |> Map.put("sweep", true)
    |> new(schedule_in: @sweep_delay_seconds)
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
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
    # Tenant-scoped: `notes` carries FORCE ROW LEVEL SECURITY, so unscoped this
    # returns nil and old-path recovery silently fails — the rename's link
    # rewrite then has nothing to rewrite toward, with no error. `user.id` is
    # in scope; it is already in the WHERE clause below.
    #
    # Only the READ is scoped. The decrypt below derives the user's DEK and
    # stays OUTSIDE the scope for the reason given on `Links.resolve_target/4`:
    # a KMS provider round trip inside the scope would hold row locks for the
    # provider's latency.
    {:ok, tombstone} =
      Repo.with_tenant(user.id, fn ->
        Repo.one(
          from(n in Note,
            where:
              n.user_id == ^user.id and n.vault_id == ^vault.id and n.kind == "note" and
                not is_nil(n.deleted_at),
            # notes_path_tomb (vault_id, path_id, seq): a backward probe.
            where: ^Engram.Notes.Keys.eq(:path, old_path_hmac),
            order_by: [desc: n.seq],
            limit: 1,
            # The path only: never the body.
            select: struct(n, ^Note.path_fields())
          )
        )
      end)

    decrypt_tombstone_path(tombstone, user, &Crypto.maybe_decrypt_note_fields/2)
  end

  defp tombstone_old_path(user, vault, :attachment, old_path_hmac) do
    # Tenant-scoped for the same reason as the `:note` clause above;
    # `attachments` is also FORCE ROW LEVEL SECURITY.
    {:ok, tombstone} =
      Repo.with_tenant(user.id, fn ->
        Repo.one(
          from(a in Attachment,
            where:
              a.user_id == ^user.id and a.vault_id == ^vault.id and
                a.path_hmac == ^old_path_hmac and not is_nil(a.deleted_at),
            order_by: [desc: a.seq],
            limit: 1
          )
        )
      end)

    decrypt_tombstone_path(tombstone, user, &Crypto.maybe_decrypt_attachment_fields/2)
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

  # `{source_id, target_or_targets}` pairs: each linking note is written once.
  defp rewrite_each(user, vault, pairs) do
    Enum.each(pairs, fn {source_id, target} ->
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
              target_id: if(is_map(target), do: target.id),
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
