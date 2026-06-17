defmodule Engram.Sync do
  @moduledoc """
  Ordered change-log sync: opaque (seq,id) cursor codec + per-device
  watermark recording (the GC/eviction record; NOT the pagination source
  of truth — clients hold their own position).
  """
  alias Engram.Repo

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
