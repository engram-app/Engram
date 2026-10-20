defmodule Engram.Notes.NoteBody do
  @moduledoc """
  A note's body, 1:1 with `notes` (migration 20261021110100): materialized
  content, CRDT state and manifest head. Written only by the
  `notes_sync_body` trigger; nothing reads it until the `NoteSplit` ledger
  is done and readers switch (a later release).

  `content_ct` / `crdt_ct` hold `nonce || ciphertext`
  (`Engram.Crypto.Envelope.split_merged/1`).
  """
  use Ecto.Schema

  @primary_key {:note_id, :binary_id, autogenerate: false}
  schema "note_bodies" do
    field :user_id, :binary_id
    field :key_version, :integer
    field :content_ct, :binary
    field :crdt_ct, :binary
    field :crdt_head, :binary
  end
end
