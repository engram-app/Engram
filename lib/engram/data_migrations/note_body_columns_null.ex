defmodule Engram.DataMigrations.NoteBodyColumnsNull do
  @moduledoc """
  R8(b2) migrate-data: sets `notes.content_ciphertext` and
  `notes.crdt_state_ciphertext` NULL where `note_bodies` already holds the
  same envelope, so every body is stored once. From R8(b2) on no writer sets
  those columns (the `Note` fields are virtual) and every read takes the
  body from `note_bodies`; R8(c) drops the columns. The nonces
  (`content_nonce`, `crdt_state_nonce`) and `crdt_head` stay: the write
  fences compare the nonces.

  A column is nulled only when its body row (owned by the same user) holds
  the same envelope: the same 13-byte nonce field, the same length and the
  same 16-byte AEAD tag (the last bytes), the cheap slices `NoteBody` uses.
  Anything else (no body row yet, a NULL nonce, a body that disagrees) is
  left as it is and keeps the ledger open: a row `NoteSplit` has not reached
  is nulled once it has, and a real disagreement must be looked at before
  R8(c) drops the column. Nulling the CRDT ciphertext alone (same nonce)
  does not fire `notes_crdt_head_invalidate`, so heads stay warm; no
  `seq`/`updated_at` moves, no fan-out.

  Discovery and writes go through `Engram.Backfill.IdWindows.heal_pass/4`
  (`notes` primary-key windows of 200, at most 10,000 rows per pass; one
  fleet walk on the maintenance pool on SaaS, per tenant on self-host). Each
  window is one statement under `SET LOCAL lock_timeout = '2s'` and
  `statement_timeout = '5s'`, locking with `FOR UPDATE OF n SKIP LOCKED`: a
  row a writer holds is skipped and counts as left.

  Blocked (the pass walks nothing, resets its walk and stays open) unless:

    * the `notes_sync_body` copy trigger is gone (it would copy the NULLs);
    * `notes_crdt_head_invalidate` fires on `crdt_state_nonce` (20261106110000),
      so a nonce-only write still resets the head;
    * every connected cluster node runs release A (R8(b1)) or later, i.e.
      has `NoteBody.put!/2` (`Readiness.peers_report/4`, the fleet gate
      `FileTimes` uses). An older node's `NoteBody.sync!/3` copies a NULL
      `notes` ciphertext over a body. A single node (self-host) passes.

  Kill switch: `enabled?/0` is the `note_body_columns_null` service
  override (default on). Not re-verified: no release from R8(b2) on writes
  the columns, and the rollback floor is release A (rolling back below it
  is data loss: its readers take the `notes` columns).
  """
  @behaviour Engram.DataMigration

  alias Engram.Backfill.IdWindows
  alias Engram.Cluster.Readiness
  alias Engram.Logger.Metadata
  alias Engram.Notes.Note
  alias Engram.Notes.NoteBody
  alias Engram.Repo

  require Logger

  @batch 200
  @max_fixed 10_000
  @erpc_timeout_ms 5_000

  @impl true
  def name, do: "note_body_columns_null"

  @impl true
  def version, do: 1

  @doc """
  Kill switch: the `note_body_columns_null` service override (default on).
  Off, the runner runs no pass and the ledger stays open.
  """
  @impl true
  def enabled?, do: Engram.ServiceConfig.get(:note_body_columns_null, true) == true

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  # `batch:` / `max_fixed:` override the window size and per-pass cap,
  # `fleet:` the `Readiness.peers_report/4` collaborators.
  def run_pass(opts) do
    case blocker(opts) do
      nil -> walk(opts)
      reason -> blocked(reason)
    end
  end

  @doc false
  # The first guard that fails, or nil.
  def blocker(opts \\ []) do
    cond do
      copy_trigger?() -> :copy_trigger_present
      not head_trigger_on_nonce?() -> :head_trigger_not_on_nonce
      true -> fleet_blocker(opts)
    end
  end

  @copy_trigger_sql """
  SELECT count(*)::int FROM pg_trigger
  WHERE tgname = 'notes_sync_body' AND tgrelid = 'public.notes'::regclass AND NOT tgisinternal
  """

  @head_trigger_sql """
  SELECT count(*)::int FROM pg_trigger
  WHERE tgname = 'notes_crdt_head_invalidate' AND tgrelid = 'public.notes'::regclass
    AND NOT tgisinternal AND pg_get_triggerdef(oid) LIKE '%crdt_state_nonce%'
  """

  defp copy_trigger?, do: match?(%{rows: [[n]]} when n > 0, Repo.query!(@copy_trigger_sql, []))

  defp head_trigger_on_nonce?,
    do: match?(%{rows: [[n]]} when n > 0, Repo.query!(@head_trigger_sql, []))

  # Release A is the first with `NoteBody.put!/2`: a peer without it is
  # older. `function_exported?` is enough: releases boot in embedded mode,
  # every module loaded.
  defp fleet_blocker(opts) do
    fleet = Keyword.merge([sync: fn -> :ok end], Keyword.get(opts, :fleet, []))
    {probe, fleet} = Keyword.pop(fleet, :multicall, &probe/1)
    fleet = Keyword.put(fleet, :multicall, &Enum.map(probe.(&1), fn r -> level(r) end))

    case Readiness.peers_report(NoteBody, :put!, 1, fleet) do
      :ok -> nil
      {reason, node} -> {reason, node}
    end
  end

  defp probe(peers),
    do:
      :erpc.multicall(peers, :erlang, :function_exported, [NoteBody, :put!, 2], @erpc_timeout_ms)

  # `peers_report/4` wants an integer level per peer.
  defp level({:ok, true}), do: {:ok, 1}
  defp level({:ok, false}), do: {:ok, 0}
  defp level(other), do: other

  defp blocked(reason) do
    IdWindows.reset_walk(name())

    Logger.info(
      "note body columns null blocked",
      Metadata.with_category(:info, :data, reason: inspect(reason))
    )

    {:more, rows: 0, blocked: 1}
  end

  defp walk(opts) do
    IdWindows.heal_pass(name(), Note, &null/2,
      batch_size: Keyword.get(opts, :batch, @batch),
      max_fixed: Keyword.get(opts, :max_fixed, @max_fixed)
    )
  end

  # Per ciphertext column: the body row holds the same envelope (same
  # nonce field, length and tag). `n` the notes row, `b` its body row.
  in_step = fn ct, nonce, body ->
    prefix =
      "CASE WHEN length(n.#{nonce}) = 13 THEN n.#{nonce} ELSE '\\x00'::bytea || n.#{nonce} END"

    """
    (n.#{ct} IS NOT NULL AND n.#{nonce} IS NOT NULL AND b.#{body} IS NOT NULL
      AND substring(b.#{body} FROM 1 FOR 13) = substring((#{prefix}) FROM 1 FOR 13)
      AND octet_length(b.#{body}) = 13 + octet_length(n.#{ct})
      AND substring(b.#{body} FROM octet_length(b.#{body}) - 15)
        = substring(n.#{ct} FROM greatest(octet_length(n.#{ct}) - 15, 1)))
    """
  end

  content = in_step.("content_ciphertext", "content_nonce", "content_ct")
  crdt = in_step.("crdt_state_ciphertext", "crdt_state_nonce", "crdt_ct")

  # One statement: lock the window's in-step rows (skipping a row a writer
  # holds), null the in-step columns. `= ANY(ARRAY(...))`: an InitPlan,
  # evaluated once (see `NoteSplit.touch/2`).
  @null_sql """
  UPDATE notes AS n SET
    content_ciphertext = CASE WHEN #{content} THEN NULL ELSE n.content_ciphertext END,
    crdt_state_ciphertext = CASE WHEN #{crdt} THEN NULL ELSE n.crdt_state_ciphertext END
  FROM note_bodies AS b
  WHERE b.note_id = n.id AND b.user_id = n.user_id
    AND n.id = ANY(ARRAY(
      SELECT n.id FROM notes AS n
      JOIN note_bodies AS b ON b.note_id = n.id AND b.user_id = n.user_id
      WHERE n.id = ANY($1) AND n.kind = 'note' AND (#{content} OR #{crdt})
      ORDER BY n.id
      FOR UPDATE OF n SKIP LOCKED))
  RETURNING n.id
  """

  # What is left in a window: a ciphertext still on `notes` (skipped on a
  # lock, drifted, or with no body row yet). Varlena headers only.
  @left_sql """
  SELECT count(*)::int FROM notes AS n
  WHERE n.id = ANY($1)
    AND (n.content_ciphertext IS NOT NULL OR n.crdt_state_ciphertext IS NOT NULL)
  """

  defp null(ids, %{repo: repo}) do
    ids = Enum.map(ids, &Ecto.UUID.dump!/1)
    _ = repo.query!("SET LOCAL lock_timeout = '2s'", [])
    _ = repo.query!("SET LOCAL statement_timeout = '5s'", [])
    %{num_rows: fixed} = repo.query!(@null_sql, [ids])
    %{rows: [[left]]} = repo.query!(@left_sql, [ids])
    {fixed, left > 0}
  end
end
