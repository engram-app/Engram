defmodule Engram.Bookkeeping.Drain do
  @moduledoc """
  Heals app-kept bookkeeping drift in time proportional to the drift, not the
  table. Replaces the daily re-verify walk of `EnvelopeFormat`,
  `LinkResolutionKeys` and `NotePayloadStamps`, and the notes half of
  `FolderTable`'s (Job Load Audit 2026-11-03, item 1).

  Some bookkeeping needs a per-user key (envelope format, link-key HMACs,
  Qdrant payload stamps, folder rows), so a database trigger cannot keep it,
  and a previous-release writer during a rolling deploy skips it. Each kind
  has a partial index whose predicate is the drift test (migration
  20261103000200, and the link-key indexes of 20261018230001), empty in steady
  state. One tick runs one `SELECT DISTINCT user_id ... LIMIT 100` per index
  (an index read of a page or two), then hands the users to the worker that
  owns the repair. Nothing here reads `notes` outside those indexes.

  The predicate texts below must equal the indexes' (Postgres uses a partial
  index only for a query carrying the same text); `drain_test.exs` pins every
  probe to its index with EXPLAIN.

  The repairs are the existing ones: `ReencodeEnvelopes`, `BackfillLinkKeys`
  and `ReconcileNotePayloads` per-user chains (their own rotation gate,
  `unique` and compression gate apply), and `FolderTable.run_pass/1` for the
  users with an unresolved folder reference.
  """

  alias Engram.Backfill.TenantScan
  alias Engram.Crypto.Envelope
  alias Engram.DataMigrations.FolderTable
  alias Engram.Logger.Metadata
  alias Engram.Repo
  alias Engram.Workers.BackfillLinkKeys
  alias Engram.Workers.ReconcileNotePayloads
  alias Engram.Workers.ReencodeEnvelopes

  require Logger

  # Each probe is a LITERAL statement (no interpolation: it is a security-scanner
  # finding, and a computed predicate is how a probe silently stops matching its
  # index). `$1` is the user in a per-user scope (self-host), NULL on the fleet
  # pool; the OR is a filter on the index entries and does not affect which
  # partial index the predicate selects. At most 100 users per probe per tick;
  # the rest are reached on later ticks as the earlier ones leave the index.
  @envelope [
    {"note_bodies",
     """
     SELECT DISTINCT user_id FROM note_bodies
     WHERE substring(content_ct FROM 1 FOR 1) = '\\x00'::bytea AND octet_length(content_ct) > 29
       AND key_version >= 2 AND ($1::uuid IS NULL OR user_id = $1) LIMIT 100
     """},
    {"note_bodies",
     """
     SELECT DISTINCT user_id FROM note_bodies
     WHERE substring(crdt_ct FROM 1 FOR 1) = '\\x00'::bytea AND octet_length(crdt_ct) > 29
       AND ($1::uuid IS NULL OR user_id = $1) LIMIT 100
     """},
    {"crdt_update_log",
     """
     SELECT DISTINCT user_id FROM crdt_update_log
     WHERE octet_length(update_nonce) = 12 AND octet_length(update_ciphertext) > 16
       AND ($1::uuid IS NULL OR user_id = $1) LIMIT 100
     """},
    {"vault_index_states",
     """
     SELECT DISTINCT user_id FROM vault_index_states
     WHERE octet_length(state_nonce) = 12 AND octet_length(state_ciphertext) > 16
       AND ($1::uuid IS NULL OR user_id = $1) LIMIT 100
     """},
    {"vault_index_update_log",
     """
     SELECT DISTINCT user_id FROM vault_index_update_log
     WHERE octet_length(update_nonce) = 12 AND octet_length(update_ciphertext) > 16
       AND ($1::uuid IS NULL OR user_id = $1) LIMIT 100
     """}
  ]

  # The Unicode version is inlined as in `*_link_keys_stale_index`
  # (20261018230001): "15.1.0" = 0x31352e312e30. `LinkKeysIndexTest` and the
  # plan test fail together when an Elixir upgrade moves it.
  @link_keys [
    {"notes",
     """
     SELECT DISTINCT user_id FROM notes
     WHERE basename_hmac IS NOT NULL
       AND link_keys_stamp IS DISTINCT FROM (path_nonce || '\\x31352e312e30'::bytea)
       AND ($1::uuid IS NULL OR user_id = $1) LIMIT 100
     """},
    {"attachments",
     """
     SELECT DISTINCT user_id FROM attachments
     WHERE basename_hmac IS NOT NULL
       AND link_keys_stamp IS DISTINCT FROM (path_nonce || '\\x31352e312e30'::bytea)
       AND ($1::uuid IS NULL OR user_id = $1) LIMIT 100
     """},
    {"note_links",
     """
     SELECT DISTINCT user_id FROM note_links
     WHERE link_keys_stamp IS DISTINCT FROM (target_text_nonce || '\\x31352e312e30'::bytea)
       AND ($1::uuid IS NULL OR user_id = $1) LIMIT 100
     """}
  ]

  @payload [
    {"note_index_state",
     """
     SELECT DISTINCT user_id FROM note_index_state
     WHERE payload_hash IS NULL AND chunk_count > 0
       AND ($1::uuid IS NULL OR user_id = $1) LIMIT 100
     """}
  ]

  @folder [
    {"notes",
     """
     SELECT DISTINCT user_id FROM notes
     WHERE kind = 'note' AND deleted_at IS NULL AND folder_ref_id IS NULL
       AND octet_length(folder_ciphertext) > 16
       AND ($1::uuid IS NULL OR user_id = $1) LIMIT 100
     """}
  ]

  @doc """
  `{table, sql}` for each probe, by kind (`:envelope | :link_keys | :payload |
  :folder`). Public for the plan test.
  """
  @spec probes(atom()) :: [{String.t(), String.t()}]
  def probes(:envelope), do: @envelope
  def probes(:link_keys), do: @link_keys
  def probes(:payload), do: @payload
  def probes(:folder), do: @folder

  @doc "One tick. Returns the users handed to each repair."
  @spec run() :: %{atom() => non_neg_integer()}
  def run do
    counts = %{
      envelope: envelope(),
      link_keys: enqueue(:link_keys, BackfillLinkKeys, &BackfillLinkKeys.missing_rows?/1),
      payload: enqueue(:payload, ReconcileNotePayloads, &ReconcileNotePayloads.unstamped_rows?/1),
      folder: folder()
    }

    Logger.info(
      "bookkeeping drain tick",
      Metadata.with_category(:info, :oban, Map.to_list(counts))
    )

    counts
  end

  # A note's body is probed on `note_bodies` (the copy that survives the R8
  # contract) while the worker still selects on the `notes` columns, so each
  # candidate is confirmed with the worker's own predicate. While compression is
  # off (or a node cannot read format 1) a re-encode would write format 0 again:
  # the worker cancels itself, so the drain does not queue it.
  defp envelope do
    if Envelope.compression_on?(),
      do: enqueue(:envelope, ReencodeEnvelopes, &ReencodeEnvelopes.legacy_rows?/1),
      else: 0
  end

  # The probe is a superset of the worker's selection (an index cannot carry
  # every term), so each candidate is confirmed with the worker's own
  # predicate before it is queued: a perpetual false positive would otherwise
  # re-queue a no-op job every tick.
  defp enqueue(kind, worker, confirm) do
    kind |> users() |> Enum.filter(confirm) |> then(&TenantScan.enqueue_users(worker, &1))
  end

  # A user whose note sits in a folder with no row yet: `FolderTable` creates
  # the folder rows and points the notes. Only once its ledger has closed; an
  # open ledger is the hourly runner's.
  defp folder do
    case users(:folder) do
      [] ->
        0

      users ->
        if FolderTable.done?(), do: FolderTable.run_pass(user_ids: users)
        length(users)
    end
  end

  defp users(kind) do
    kind
    |> probes()
    |> Enum.flat_map(fn {_table, sql} -> probe(sql) end)
    |> Enum.uniq()
  end

  # Sobelow cannot see that `sql` is one of this module's literal probes above
  # (never input, never interpolated), so it reports the variable argument.
  # sobelow_skip ["SQL.Query"]
  defp probe(sql) do
    case TenantScan.pool() do
      {:fleet, repo} ->
        repo.query!(sql, [nil]).rows |> Enum.map(&load/1)

      :per_user ->
        TenantScan.flat_map_users(fn uid ->
          Repo.query!(sql, [Ecto.UUID.dump!(uid)]).rows |> Enum.map(&load/1)
        end)
    end
  end

  defp load([id]), do: Ecto.UUID.load!(id)
end
