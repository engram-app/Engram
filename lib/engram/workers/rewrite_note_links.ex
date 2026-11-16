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
  moved note (and per moved attachment), so a note linking N moved rows was
  rewritten N times (staging, 1k moved notes: 1,000 version bumps on one
  index note in 8 min, 1.13 GB of WAL). `new_for_folder/3` queues one chain
  per kind of moved row (the note cascade, the attachment bulk move), whose
  args carry every moved row as a `"targets"` entry (the per-note args' ids
  and HMACs plus `target_kind`, up to 1,000 per chain). Each
  page takes the next linking notes of ANY moved basename (keyset on
  `source_note_id`), builds only the targets that page's notes name, in a
  constant number of queries (one tombstone read per kind, then
  `Rewriter.build_folder_targets/3`), and rewrites each linking note ONCE
  with every edit: one Y-update, one link rebuild. A note linking moved
  notes AND moved attachments is written once per chain (twice). A target
  that cannot be built (gone, old path unrecoverable) is skipped and
  counted; the rest proceed. Folder chains run at `folder_priority/0`,
  behind single renames and repairs.

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

  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Crypto.RotationGate
  alias Engram.Links.Rewriter
  alias Engram.Logger.Metadata
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
  @folder_priority 1

  # The tagged error atoms the rewrite pipeline actually produces
  # (rewrite_source_note/attempt/persist + this worker's own path recovery).
  @failure_reasons [
    :head_advanced,
    :room_gone,
    :target_gone,
    :version_conflict,
    :path_undecryptable,
    :decrypt_failed,
    :old_path_unrecoverable,
    # A folder entry whose HMACs are missing or not base64 (skipped).
    :invalid_hmac_base64
  ]

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @doc "False while the `:link_rewrite` kill switch is off."
  @spec enabled?() :: boolean()
  def enabled?, do: Engram.ServiceConfig.get(:link_rewrite, true) != false

  @doc """
  Folder chains run behind single renames and repairs (priority 0) on the
  one `link_rewrite` slot, so a big move never holds another tenant's
  single rename behind every chunk's first page. Successors and sweeps keep it.
  """
  @spec folder_priority() :: 1
  def folder_priority, do: @folder_priority

  @doc """
  The folder-move chains for `moves`, one per 1,000-row chunk.
  `moves` are `{kind, target_id, old_path_hmac_b64, old_basename_hmac_b64}`,
  notes or attachments (T3.2: ids and HMACs only).
  """
  @spec new_for_folder(binary(), binary(), [
          {:note | :attachment, binary(), String.t(), String.t()}
        ]) :: [Ecto.Changeset.t()]
  def new_for_folder(user_id, vault_id, moves) do
    moves
    |> Enum.chunk_every(@max_folder_targets)
    |> Enum.map(fn chunk ->
      new(
        %{
          "user_id" => user_id,
          "vault_id" => vault_id,
          "cursor" => @start_cursor,
          "targets" =>
            Enum.map(chunk, fn {kind, id, path_hmac, basename_hmac} ->
              %{
                "target_kind" => Atom.to_string(kind),
                "target_id" => id,
                "old_path_hmac" => path_hmac,
                "old_basename_hmac" => basename_hmac
              }
            end)
        },
        priority: @folder_priority
      )
    end)
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
      by_hmac = entries |> decoded_entries(cursor) |> Enum.group_by(& &1.basename_hmac)
      hmacs = Map.keys(by_hmac)
      ids = Rewriter.source_note_ids(user, vault, hmacs, cursor, batch_size)
      linked = Rewriter.linked_basenames(user, vault, ids, hmacs)

      targets =
        linked
        |> Enum.map(&elem(&1, 1))
        |> Enum.uniq()
        |> Enum.flat_map(&Map.fetch!(by_hmac, &1))
        |> then(&folder_targets(user, vault, &1))
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
      |> new(priority: priority(args))
      |> Oban.insert()
      |> case do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      maybe_enqueue_sweep(args)
    end
  end

  # A page's folder entries to rewrite targets, in a constant number of
  # queries: one tombstone read per kind for the old paths, then
  # `Rewriter.build_folder_targets/3`. An entry whose old path cannot be
  # recovered, or whose row is gone, is counted and skipped, so it never stops
  # the rest of the folder's rewrite (the per-note chain discards instead).
  defp folder_targets(user, vault, entries) do
    {moves, lost} =
      entries
      |> Enum.group_by(& &1.kind)
      |> Enum.flat_map(fn {kind, group} ->
        paths = Rewriter.tombstone_old_paths(user, vault, kind, Enum.map(group, & &1.path_hmac))
        Enum.map(group, &{kind, &1.id, Map.get(paths, &1.path_hmac)})
      end)
      |> Enum.split_with(fn {_kind, _id, path} -> is_binary(path) end)

    {targets, gone} = Rewriter.build_folder_targets(user, vault, moves)

    count_failed(:old_path_unrecoverable, length(lost))
    count_failed(:target_gone, length(gone))
    targets
  end

  # Folder entries with both HMACs decoded. Entries are server-built, so a
  # malformed or keyless one is a bug: it is skipped, never allowed to fail the
  # page and, after retries, discard the chain. Every page repeats the
  # entries, so only a walk's first page (the chain head or its sweep) logs
  # (ids only) and counts them.
  defp decoded_entries(entries, cursor) do
    {good, bad} =
      Enum.reduce(entries, {[], []}, fn e, {good, bad} ->
        with {:ok, path_hmac} <- decode_b64(e["old_path_hmac"]),
             {:ok, basename_hmac} <- decode_b64(e["old_basename_hmac"]) do
          entry = %{kind: kind_from(e["target_kind"]), id: e["target_id"]}
          {[Map.merge(entry, %{path_hmac: path_hmac, basename_hmac: basename_hmac}) | good], bad}
        else
          {:discard, :invalid_hmac_base64} -> {good, [e["target_id"] | bad]}
        end
      end)

    if bad != [] and cursor == @start_cursor do
      Logger.warning(
        "link rewrite skipped a malformed folder entry",
        Metadata.with_category(:warning, :sync, target_id: hd(bad), total_count: length(bad))
      )

      count_failed(:invalid_hmac_base64, length(bad))
    end

    Enum.reverse(good)
  end

  defp count_failed(_reason, 0), do: :ok

  defp count_failed(reason, n),
    do: :telemetry.execute([:engram, :links, :rewrite, :failed], %{count: n}, %{reason: reason})

  # Chain terminated. A plain run schedules one delayed sweep to catch any
  # edge that indexed in after this walk started (see moduledoc). A sweep
  # run terminates quietly — no third pass.
  defp maybe_enqueue_sweep(%{"sweep" => true}), do: :ok

  defp maybe_enqueue_sweep(args) do
    args
    |> Map.put("cursor", @start_cursor)
    |> Map.put("sweep", true)
    |> new(schedule_in: @sweep_delay_seconds, priority: priority(args))
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp priority(%{"targets" => _}), do: @folder_priority
  defp priority(_args), do: 0

  defp kind_from("attachment"), do: :attachment
  defp kind_from(_), do: :note

  defp decode_b64(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:discard, :invalid_hmac_base64}
    end
  end

  # A missing key is as malformed as a bad encoding.
  defp decode_b64(_missing), do: {:discard, :invalid_hmac_base64}

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
  defp tombstone_old_path(user, vault, kind, old_path_hmac) do
    case Rewriter.tombstone_old_paths(user, vault, kind, [old_path_hmac]) do
      %{^old_path_hmac => path} -> {:ok, path}
      _ -> {:discard, :old_path_unrecoverable}
    end
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
          | :invalid_hmac_base64
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
