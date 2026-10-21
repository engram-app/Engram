defmodule Engram.Links.NoteLink do
  @moduledoc """
  One row per link occurrence in a note (issue #591) — both `[[wikilink]]`
  and markdown `[label](target.md)` syntax (#1302). An edge stores its
  target's name, never a resolved id: `Engram.Links` resolves it on read.

  The `target_note_id`/`target_attachment_id` columns are no longer read or
  written; a later migration drops them.
  """
  use Engram.Schema

  schema "note_links" do
    field :target_text, :string, virtual: true, redact: true
    field :alias, :string, virtual: true, redact: true
    field :anchor, :string, virtual: true, redact: true

    field :target_text_ciphertext, :binary
    field :target_text_nonce, :binary
    field :target_basename_hmac, :binary
    # `Engram.Links.target_key_hmac/2` of the target; NULL = not computed.
    field :target_key_hmac, :binary
    field :link_keys_stamp, :binary
    field :alias_ciphertext, :binary
    field :alias_nonce, :binary
    field :anchor_ciphertext, :binary
    field :anchor_nonce, :binary
    field :link_type, :string
    field :position, :integer
    field :dek_version, :integer, default: 2

    belongs_to :user, Engram.Accounts.User
    belongs_to :vault, Engram.Vaults.Vault
    belongs_to :source_note, Engram.Notes.Note

    timestamps(type: :utc_datetime_usec, inserted_at: :inserted_at, updated_at: false)
  end
end
