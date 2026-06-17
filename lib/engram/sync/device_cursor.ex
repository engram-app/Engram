defmodule Engram.Sync.DeviceCursor do
  @moduledoc """
  Per-(vault, device) sync watermark — the GC/eviction record for the
  ordered change-log. NOT the pagination source of truth; clients hold
  their own cursor position. `last_seq` is the highest seq the device has
  confirmed-applied (recorded via pull-carries-ack, monotonic).

  The table has no surrogate `id` — its natural key is the composite
  (vault_id, device_id), so this schema does NOT use `Engram.Schema`
  (which would inject a UUID `id` primary key the column doesn't have).
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type Ecto.UUID
  schema "vault_device_cursors" do
    field :vault_id, Ecto.UUID, primary_key: true
    field :device_id, :string, primary_key: true
    field :last_seq, :integer, default: 0
    field :last_seen_at, :utc_datetime
  end
end
