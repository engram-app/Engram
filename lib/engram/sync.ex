defmodule Engram.Sync do
  @moduledoc """
  Ordered change-log sync: opaque (seq,id) cursor codec + per-device
  watermark recording (the GC/eviction record; NOT the pagination source
  of truth — clients hold their own position).
  """
  alias Engram.{Attachments, Notes, Repo}

  @doc """
  One seq-ordered page merging the notes + attachments change feeds for a vault.

  `seq` is a vault-global sequence (both `Notes` and `Attachments` upserts draw
  from `Vaults.next_seq!/1`), so a note and an attachment can never share a seq —
  the merged stream is a total order and an integer cursor paginates it
  correctly. Each row is tagged `:type` (`:note` | `:attachment`) so the client
  dispatches apply per kind.

  Fetches `limit + 1` from EACH feed so the merged page can still fill `limit`
  when one feed is exhausted inside the window, then trims to `limit`. Returns
  `%{page: [...], has_more: boolean, next: {seq, id} | nil}`.

  Both feeds internally cap their page at 500 rows; callers must clamp `limit`
  to that ceiling (see `SyncController`), else a feed could return its capped 500
  (< limit) while in-range rows remain and the trim branch would be skipped —
  silently dropping rows.
  """
  def merged_changes_page(user, vault, after_seq, after_id, limit, fields)
      when is_integer(after_seq) and is_integer(limit) do
    {:ok, %{changes: notes, has_more: notes_more}} =
      Notes.list_changes_by_seq(user, vault, after_seq,
        after_id: after_id,
        limit: limit + 1,
        fields: fields
      )

    # Attachments carry no note content, so the `fields` projection is n/a here.
    {:ok, %{changes: atts, has_more: atts_more}} =
      Attachments.list_changes_by_seq(user, vault, after_seq,
        after_id: after_id,
        limit: limit + 1
      )

    merged =
      (Enum.map(notes, &Map.put(&1, :type, :note)) ++
         Enum.map(atts, &Map.put(&1, :type, :attachment)))
      |> Enum.sort_by(&{&1.seq, &1.id})

    {page, has_more} =
      if length(merged) > limit do
        {Enum.take(merged, limit), true}
      else
        {merged, notes_more or atts_more}
      end

    next =
      if has_more do
        last = List.last(page)
        {last.seq, last.id}
      end

    %{page: page, has_more: has_more, next: next}
  end

  @doc "Opaque cursor token = url-safe base64 of `<seq>:<id>`."
  def encode_cursor(seq, id) when is_integer(seq) and is_binary(id),
    do: Base.url_encode64("#{seq}:#{id}", padding: false)

  @doc """
  Decodes an opaque cursor back to `{seq, id}`. `nil` decodes to `{:ok, nil}`
  (a first-pull / no-cursor request); anything malformed is
  `{:error, :invalid_cursor}` so callers can 400 rather than crash.
  """
  def decode_cursor(nil), do: {:ok, nil}

  def decode_cursor(tok) when is_binary(tok) do
    with {:ok, raw} <- Base.url_decode64(tok, padding: false),
         [seq_str, id_str] <- String.split(raw, ":", parts: 2),
         {seq, ""} <- Integer.parse(seq_str),
         {:ok, id} <- Ecto.UUID.cast(id_str) do
      {:ok, {seq, id}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  def decode_cursor(_), do: {:error, :invalid_cursor}

  @doc "Retention floor for HISTORY_EXPIRED. 0 until PR D (compaction) lands."
  def retention_floor(_vault), do: 0

  @doc """
  Records a device's confirmed-applied watermark (pull-carries-ack).

  Monotonic via `GREATEST` so a lagging/out-of-order pull never regresses
  the stored `last_seq`. No-op when `device_id` is nil/blank (e.g. a
  legacy client that doesn't send one).

  Single `INSERT ... ON CONFLICT DO UPDATE` so concurrent pulls for the
  same (vault, device) can't interleave an insert + a stale update.
  Runs inside `Repo.with_tenant/2` so the write executes as `engram_app`
  with the tenant context set. The table is not under RLS (it's a
  GC/eviction record, not tenant-row-policy data), but `with_tenant`
  keeps the role/connection discipline consistent with every other write.
  """
  def record_cursor(_user, _vault, device_id, _seq) when device_id in [nil, ""], do: :ok

  def record_cursor(user, vault, device_id, seq) when is_integer(seq) do
    now = DateTime.utc_now(:second)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.query!(
          """
          INSERT INTO vault_device_cursors (vault_id, device_id, last_seq, last_seen_at)
          VALUES ($1, $2, $3, $4)
          ON CONFLICT (vault_id, device_id) DO UPDATE
            SET last_seq = GREATEST(vault_device_cursors.last_seq, EXCLUDED.last_seq),
                last_seen_at = EXCLUDED.last_seen_at
          """,
          [Ecto.UUID.dump!(vault.id), device_id, seq, now]
        )
      end)

    :ok
  end
end
