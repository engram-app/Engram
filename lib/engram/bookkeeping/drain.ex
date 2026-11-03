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
  alias Engram.Links
  alias Engram.Logger.Metadata
  alias Engram.Repo
  alias Engram.Workers.BackfillLinkKeys
  alias Engram.Workers.ReconcileNotePayloads
  alias Engram.Workers.ReencodeEnvelopes

  require Logger

  # Users read per probe per tick; the rest are reached on later ticks as the
  # earlier ones leave the index.
  @users_per_probe 100

  @envelope [
    {"notes",
     "octet_length(content_nonce) = 12 AND octet_length(content_ciphertext) > 16 AND dek_version >= 2"},
    {"notes", "octet_length(crdt_state_nonce) = 12 AND octet_length(crdt_state_ciphertext) > 16"},
    {"crdt_update_log",
     "octet_length(update_nonce) = 12 AND octet_length(update_ciphertext) > 16"},
    {"vault_index_states",
     "octet_length(state_nonce) = 12 AND octet_length(state_ciphertext) > 16"},
    {"vault_index_update_log",
     "octet_length(update_nonce) = 12 AND octet_length(update_ciphertext) > 16"}
  ]

  @payload [{"note_index_state", "payload_hash IS NULL AND chunk_count > 0"}]

  @folder [
    {"notes",
     "kind = 'note' AND deleted_at IS NULL AND folder_ref_id IS NULL AND octet_length(folder_ciphertext) > 16"}
  ]

  @doc """
  `{table, predicate}` for each probe, by kind (`:envelope | :link_keys |
  :payload | :folder`). Public for the plan test.
  """
  @spec probes(atom()) :: [{String.t(), String.t()}]
  def probes(:envelope), do: @envelope
  def probes(:payload), do: @payload
  def probes(:folder), do: @folder

  # The link-key stale test with the Unicode version inlined, as in
  # `notes_link_keys_stale_index`.
  def probes(:link_keys) do
    v = "'\\x" <> Base.encode16(Links.link_keys_version(), case: :lower) <> "'::bytea"

    [
      {"notes",
       "basename_hmac IS NOT NULL AND link_keys_stamp IS DISTINCT FROM (path_nonce || #{v})"},
      {"attachments",
       "basename_hmac IS NOT NULL AND link_keys_stamp IS DISTINCT FROM (path_nonce || #{v})"},
      {"note_links", "link_keys_stamp IS DISTINCT FROM (target_text_nonce || #{v})"}
    ]
  end

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

  # The index predicate IS the worker's selection, so no second check. While
  # compression is off (or a node cannot read format 1) a re-encode would write
  # format 0 again: the worker cancels itself, so the drain does not queue it.
  defp envelope do
    if Envelope.compression_on?(),
      do: TenantScan.enqueue_users(ReencodeEnvelopes, users(:envelope)),
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
    |> Enum.flat_map(fn {table, predicate} -> probe(table, predicate) end)
    |> Enum.uniq()
  end

  defp probe(table, predicate) do
    sql = "SELECT DISTINCT user_id FROM #{table} WHERE #{predicate}"

    case TenantScan.pool() do
      {:fleet, repo} ->
        repo.query!(sql <> " LIMIT #{@users_per_probe}", []).rows |> Enum.map(&load/1)

      :per_user ->
        TenantScan.flat_map_users(fn uid ->
          Repo.query!(sql <> " AND user_id = $1 LIMIT 1", [Ecto.UUID.dump!(uid)]).rows
          |> Enum.map(&load/1)
        end)
    end
  end

  defp load([id]), do: Ecto.UUID.load!(id)
end
