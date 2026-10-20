defmodule Engram.Rebuild.ManifestVault do
  @moduledoc "A vault's BM25 `avgdl`, pinned for the v5 pass (`Engram.Rebuild`). Tenant table."
  use Ecto.Schema

  @primary_key {:vault_id, :binary_id, autogenerate: false}
  schema "rebuild_manifest_vaults" do
    field :user_id, :binary_id
    field :avgdl, :float
    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end
end
