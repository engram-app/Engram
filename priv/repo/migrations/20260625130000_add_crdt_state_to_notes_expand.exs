defmodule Engram.Repo.Migrations.AddCrdtStateToNotesExpand do
  use Ecto.Migration

  # phase/expand — additive nullable columns; no backfill. A note with no
  # crdt_state yet (NULL) is seeded lazily on its first CRDT-aware write
  # (Engram.Notes.CrdtBridge.merge_plaintext/2 starts from an empty Y.Doc).
  #
  # Posture C: both columns hold AES-256-GCM output keyed by the per-user DEK,
  # AAD-bound via Engram.Crypto.aad_for_row(:notes, :crdt_state, note.id).
  # `crdt_state_ciphertext` is the full v1 `encode_state_as_update` snapshot
  # (ciphertext || 16-byte tag); `crdt_state_nonce` is the 12-byte GCM nonce.
  def change do
    alter table(:notes) do
      add :crdt_state_ciphertext, :binary
      add :crdt_state_nonce, :binary
    end
  end
end
