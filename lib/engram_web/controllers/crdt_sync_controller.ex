defmodule EngramWeb.CrdtSyncController do
  @moduledoc """
  CRDT discovery probe (single-path sync). The REST update transport
  (`POST`/`GET /notes/:id/updates`) was DELETED in Phase E3 — Yjs deltas
  travel only over the `crdt:` socket topic. What remains is the
  non-destructive `GET /vault/heads` discovery/capability probe, a thin
  wrapper over `Engram.Notes.CrdtTransport.vault_heads/2`; auth + vault
  scoping come from the pipeline.
  """
  use EngramWeb, :controller

  alias Engram.Notes.CrdtTransport

  # GET /api/vault/heads
  def vault_heads(conn, _params) do
    user = conn.assigns.current_user
    vault = conn.assigns.current_vault
    # Non-destructive discovery feed: a dropped (undecryptable) row is caught
    # next poll. Byte-identical `%{heads: ...}` shape.
    heads = CrdtTransport.vault_heads(user, vault)
    json(conn, %{heads: heads})
  end
end
