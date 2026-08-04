defmodule Engram.Links.NoteLink do
  @moduledoc """
  One row per wikilink/embed occurrence in a note (issue #591). Edges are
  keyed by note UUIDs so renames never invalidate them; `target_note_id` /
  `target_attachment_id` both nil means a dangling link, resolvable later
  via `target_basename_hmac` (see `Engram.Links.bind_danglers_for/3`).
  """
  use Engram.Schema

  schema "note_links" do
    field :target_text, :string, virtual: true
    field :alias, :string, virtual: true
    field :anchor, :string, virtual: true

    field :target_text_ciphertext, :binary
    field :target_text_nonce, :binary
    field :target_basename_hmac, :binary
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
    belongs_to :target_note, Engram.Notes.Note
    belongs_to :target_attachment, Engram.Attachments.Attachment

    timestamps(type: :utc_datetime_usec, inserted_at: :inserted_at, updated_at: false)
  end
end
