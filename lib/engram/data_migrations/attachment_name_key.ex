defmodule Engram.DataMigrations.AttachmentNameKey do
  @moduledoc """
  O(1) folder rename plan, S6 step 6 (Engram#2523): every live attachment
  whose name and folder reference are current carries `name_key`, the
  stored key the by-name lookup reads (`Engram.Attachments.Location`). The
  `attachments_set_name_key` trigger (20261118140000) keys every row a
  writer touches; rows written before it keep a NULL key, and this ledger
  touches them: `SET name_stamp = name_stamp`, which fires the trigger and
  changes nothing else.

  Done means every keyable live row is keyed. A row that is not keyable (no
  folder row, or a stale name or reference) is not work here: it is read at
  its stored path, and `NoteName` / `FolderTable` make it keyable, after
  which their own write fires the trigger. The later write stop (S6 step 6
  phase 2) moves a folder without the attachment cascade only once this
  ledger is done; until then an unkeyed row under a moved folder would be
  found only at its old stored path.

  Discovery and writes go through `Engram.Backfill.IdWindows.heal_pass/4`
  (`attachments` primary-key windows of 200; one fleet walk on the
  maintenance pool on SaaS, per tenant on self-host). Each window is one
  statement under `SET LOCAL lock_timeout = '2s'` and `statement_timeout =
  '5s'`, `FOR NO KEY UPDATE ... SKIP LOCKED`: a row a writer holds is
  skipped and counts as left. Per row one non-HOT update (`name_key` is
  indexed). Per-pass cap: the `attachment_name_key_max_fixed` service
  override (rows, default 5,000).

  Kill switch: `enabled?/0` is the `attachment_name_key` service override
  (default on). Re-verified daily: a row the previous release writes during
  a rolling deploy is keyed by the trigger anyway, so a reopen is only a
  trigger that was missing.
  """
  @behaviour Engram.DataMigration

  alias Engram.Attachments.Attachment
  alias Engram.Backfill.IdWindows
  alias Engram.Crypto.NameKeys
  alias Engram.Logger.Metadata

  require Logger

  @batch 200
  @max_fixed 5_000

  @impl true
  def name, do: "attachment_name_key"

  @impl true
  def version, do: 1

  @doc "Kill switch: the `attachment_name_key` service override (default on)."
  @impl true
  def enabled?, do: Engram.ServiceConfig.get(:attachment_name_key, true) == true

  @impl true
  def reverify?, do: true

  @impl true
  def run_pass, do: run_pass([])

  @doc false
  # `batch:` / `max_fixed:` override the window size and per-pass cap.
  def run_pass(opts) do
    IdWindows.heal_pass(name(), Attachment, &key/2,
      batch_size: Keyword.get(opts, :batch, @batch),
      max_fixed: Keyword.get_lazy(opts, :max_fixed, &max_fixed/0)
    )
  end

  @doc false
  def max_fixed do
    case Engram.ServiceConfig.get(:attachment_name_key_max_fixed, @max_fixed) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        Logger.warning(
          "attachment_name_key_max_fixed is not a positive integer, using #{@max_fixed}",
          Metadata.with_category(:warning, :data)
        )

        @max_fixed
    end
  end

  # A live row the trigger would key but has not ($2: `NameKeys.version/0`).
  @keyable """
  a.id = ANY($1) AND a.deleted_at IS NULL AND a.name_key IS NULL
    AND a.folder_ref_id IS NOT NULL AND a.name_ci_hmac IS NOT NULL
    AND a.folder_ref_stamp = a.path_nonce AND a.name_stamp = a.path_nonce || $2::bytea
  """

  @key_sql """
  WITH c AS MATERIALIZED (
    SELECT a.id FROM attachments AS a
    WHERE #{@keyable}
    ORDER BY a.id
    FOR NO KEY UPDATE OF a SKIP LOCKED
  )
  UPDATE attachments AS a SET name_stamp = a.name_stamp
  FROM c
  WHERE a.id = c.id
  """

  @left_sql "SELECT count(*)::int FROM attachments AS a WHERE #{@keyable}"

  defp key(ids, %{repo: repo}) do
    params = [Enum.map(ids, &Ecto.UUID.dump!/1), NameKeys.version()]
    _ = repo.query!("SET LOCAL lock_timeout = '2s'", [])
    _ = repo.query!("SET LOCAL statement_timeout = '5s'", [])
    %{num_rows: fixed} = repo.query!(@key_sql, params)
    %{rows: [[left]]} = repo.query!(@left_sql, params)
    {fixed, left > 0}
  end
end
