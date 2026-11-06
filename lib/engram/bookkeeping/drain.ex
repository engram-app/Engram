defmodule Engram.Bookkeeping.Drain do
  @moduledoc """
  Heals app-kept bookkeeping drift in time proportional to the drift, not the
  table. Replaces the daily re-verify walk of `EnvelopeFormat`,
  `LinkResolutionKeys`, `NotePayloadStamps` and `FolderTable` (Job Load Audit
  2026-11-03, item 1; the attachments half of `FolderTable` since its
  reference stamp, #2413).

  Some bookkeeping needs a per-user key (envelope format, link-key HMACs,
  Qdrant payload stamps, folder rows), so a database trigger cannot keep it,
  and a previous-release writer during a rolling deploy skips it. Each kind
  has a partial index whose predicate is the drift test (migration
  20261103130200, the link-key indexes of 20261018230001 and
  `attachments_folder_ref_stale` of 20261103140100), empty in steady
  state. One tick runs one `SELECT DISTINCT user_id ... LIMIT 100` per index
  (an index read of a page or two), then hands the users to the worker that
  owns the repair. Nothing here reads `notes` outside those indexes.

  The predicate texts below must equal the indexes' (Postgres uses a partial
  index only for a query carrying the same text); `drain_test.exs` pins every
  probe to its index with EXPLAIN.

  The repairs are the existing ones: `ReencodeEnvelopes`, `BackfillLinkKeys`
  and `ReconcileNotePayloads` per-user chains (their own rotation gate,
  `unique` and compression gate apply), and `FolderTable.run_pass/1` for the
  users with an unresolved note folder reference or an attachment whose
  reference was not computed from its current path.
  """

  alias Engram.Backfill.TenantScan
  alias Engram.Crypto.Envelope
  alias Engram.DataMigrations.FolderTable
  alias Engram.Logger.Metadata
  alias Engram.Maintenance.Cursor
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
  @users_per_probe 100
  @folder_users_per_tick 10
  @folder_budget_ms 20_000

  @envelope [
    {"note_bodies",
     """
     SELECT DISTINCT user_id FROM note_bodies
     WHERE envelope_legacy AND ($1::uuid IS NULL OR user_id = $1)
       AND ($2::uuid IS NULL OR user_id > $2) ORDER BY user_id LIMIT 100
     """},
    {"crdt_update_log",
     """
     SELECT DISTINCT user_id FROM crdt_update_log
     WHERE octet_length(update_nonce) = 12 AND octet_length(update_ciphertext) > 16
       AND ($1::uuid IS NULL OR user_id = $1)
       AND ($2::uuid IS NULL OR user_id > $2) ORDER BY user_id LIMIT 100
     """},
    {"vault_index_states",
     """
     SELECT DISTINCT user_id FROM vault_index_states
     WHERE octet_length(state_nonce) = 12 AND octet_length(state_ciphertext) > 16
       AND ($1::uuid IS NULL OR user_id = $1)
       AND ($2::uuid IS NULL OR user_id > $2) ORDER BY user_id LIMIT 100
     """},
    {"vault_index_update_log",
     """
     SELECT DISTINCT user_id FROM vault_index_update_log
     WHERE octet_length(update_nonce) = 12 AND octet_length(update_ciphertext) > 16
       AND ($1::uuid IS NULL OR user_id = $1)
       AND ($2::uuid IS NULL OR user_id > $2) ORDER BY user_id LIMIT 100
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
       AND ($1::uuid IS NULL OR user_id = $1)
       AND ($2::uuid IS NULL OR user_id > $2) ORDER BY user_id LIMIT 100
     """},
    {"attachments",
     """
     SELECT DISTINCT user_id FROM attachments
     WHERE basename_hmac IS NOT NULL
       AND link_keys_stamp IS DISTINCT FROM (path_nonce || '\\x31352e312e30'::bytea)
       AND ($1::uuid IS NULL OR user_id = $1)
       AND ($2::uuid IS NULL OR user_id > $2) ORDER BY user_id LIMIT 100
     """},
    {"note_links",
     """
     SELECT DISTINCT user_id FROM note_links
     WHERE link_keys_stamp IS DISTINCT FROM (target_text_nonce || '\\x31352e312e30'::bytea)
       AND ($1::uuid IS NULL OR user_id = $1)
       AND ($2::uuid IS NULL OR user_id > $2) ORDER BY user_id LIMIT 100
     """}
  ]

  @payload [
    {"note_index_state",
     """
     SELECT DISTINCT user_id FROM note_index_state
     WHERE payload_hash IS NULL AND points > 0
       AND ($1::uuid IS NULL OR user_id = $1)
       AND ($2::uuid IS NULL OR user_id > $2) ORDER BY user_id LIMIT 100
     """}
  ]

  @folder [
    {"notes",
     """
     SELECT DISTINCT user_id FROM notes
     WHERE kind = 'note' AND deleted_at IS NULL AND folder_ref_id IS NULL
       AND octet_length(folder_ciphertext) > 16
       AND ($1::uuid IS NULL OR user_id = $1)
       AND ($2::uuid IS NULL OR user_id > $2) ORDER BY user_id LIMIT 10
     """},
    {"attachments",
     """
     SELECT DISTINCT user_id FROM attachments
     WHERE deleted_at IS NULL AND folder_ref_stamp IS DISTINCT FROM path_nonce
       AND folder_ref_stamp IS DISTINCT FROM ('\\x00'::bytea || path_nonce)
       AND ($1::uuid IS NULL OR user_id = $1)
       AND ($2::uuid IS NULL OR user_id > $2) ORDER BY user_id LIMIT 10
     """}
  ]

  @doc """
  `{table, sql}` for each probe, by kind (`:envelope | :link_keys | :payload |
  :folder`). Public for the plan test.
  """
  @spec probes(:envelope | :link_keys | :payload | :folder) :: [{String.t(), String.t()}]
  def probes(:envelope), do: @envelope
  def probes(:link_keys), do: @link_keys
  def probes(:payload), do: @payload
  def probes(:folder), do: @folder

  @doc """
  True when `user_id` has a row in one of `kind`'s drift indexes. One statement
  in the caller's transaction (inside its `Repo.with_tenant/2`): the probes'
  own text, so each arm is a read of a partial index that is empty in steady
  state.
  """
  @spec drift?(:envelope | :link_keys | :payload | :folder, Ecto.UUID.t()) :: boolean()
  # Sobelow cannot see that the statement is built only from this module's
  # literal probes (never input).
  # sobelow_skip ["SQL.Query"]
  def drift?(kind, user_id) do
    sql = kind |> probes() |> Enum.map_join(" UNION ALL ", fn {_table, sql} -> "(#{sql})" end)
    Repo.query!(sql <> " LIMIT 1", [Ecto.UUID.dump!(user_id), nil]).num_rows > 0
  end

  @doc "One tick. Returns the users handed to each repair."
  @spec run() :: %{
          envelope: non_neg_integer(),
          link_keys: non_neg_integer(),
          payload: non_neg_integer(),
          folder: non_neg_integer(),
          folder_blocked: non_neg_integer()
        }
  def run do
    {folder, folder_blocked} = folder()

    counts = %{
      envelope: envelope(),
      link_keys: enqueue(:link_keys, BackfillLinkKeys, &BackfillLinkKeys.missing_rows?/1),
      payload: enqueue(:payload, ReconcileNotePayloads, &ReconcileNotePayloads.unstamped_rows?/1),
      folder: folder,
      folder_blocked: folder_blocked
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

  # A user whose note sits in a folder with no row yet, or whose attachment's
  # reference is not stamped with its current path: `FolderTable` creates the
  # folder rows and points (and stamps) the rows. Only once its ledger has
  # closed; an open ledger is the hourly runner's.
  defp folder do
    case users(:folder) do
      [] ->
        {0, 0}

      users ->
        # A few users per tick (the probe pages `@folder_users_per_tick`, so
        # the cursor moves past exactly the users repaired), each with a short
        # attachment budget, so the tick stays inside its job timeout. A user
        # whose repair never finishes takes one slot per cursor cycle, never
        # the queue; their count is logged as `folder_blocked`.
        blocked =
          with true <- FolderTable.done?(),
               {:more, stats} <-
                 FolderTable.run_pass(user_ids: users, attachment_budget_ms: @folder_budget_ms) do
            stats[:blocked]
          else
            _ -> 0
          end

        {length(users), blocked}
    end
  end

  @doc false
  # Rows per probe page; must equal the probe SQL's LIMIT (the cursor wraps on
  # a short page).
  def page(:folder), do: @folder_users_per_tick
  def page(_kind), do: @users_per_probe

  @doc false
  # The users a tick's probes return for `kind` (tests compare them with the
  # repair worker's own selection).
  def candidates(kind), do: users(kind)

  defp users(kind) do
    kind
    |> probes()
    |> Enum.with_index()
    |> Enum.flat_map(fn {{_table, sql}, i} -> probe(sql, "drain:#{kind}:#{i}", page(kind)) end)
    |> Enum.uniq()
  end

  # Sobelow cannot see that `sql` is one of this module's literal probes above
  # (never input, never interpolated), so it reports the variable argument.
  # sobelow_skip ["SQL.Query"]
  defp probe(sql, cursor, page) do
    case TenantScan.pool() do
      # Fleet: the 100 users after the last tick's, wrapping at the end, so
      # users whose repair can never finish cannot take every tick.
      {:fleet, repo} ->
        from = Cursor.get(cursor)
        after_id = from && Ecto.UUID.dump!(from["user_id"])
        users = repo.query!(sql, [nil, after_id]).rows |> Enum.map(&load/1)

        :ok =
          Cursor.advance(
            cursor,
            users != [] && %{"user_id" => List.last(users)},
            length(users),
            page
          )

        users

      :per_user ->
        TenantScan.flat_map_users(fn uid ->
          Repo.query!(sql, [Ecto.UUID.dump!(uid), nil]).rows |> Enum.map(&load/1)
        end)
    end
  end

  defp load([id]), do: Ecto.UUID.load!(id)
end
