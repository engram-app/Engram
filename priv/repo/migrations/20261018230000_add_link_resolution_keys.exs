defmodule Engram.Repo.Migrations.AddLinkResolutionKeys do
  use Ecto.Migration

  @moduledoc """
  Keys that let a link read fetch only the rows it returns (resolve on read,
  2026-10-18). Each is a function of its own row, written with it:

    * `notes`/`attachments.path_ci_hmac`: HMAC of the lowercased path, so a
      folder-qualified link finds its target without decrypting every
      same-name candidate.
    * `notes`/`attachments.path_length`: grapheme length of the path, the
      first resolution tiebreak, so a bare link decrypts only the shortest
      candidates. The ciphertext length already reveals it.
    * `note_links.target_key_hmac`: HMAC of the lowercased link target, so
      backlinks select the edges that name a note instead of every edge
      sharing its basename.

  Nullable, no default: metadata-only ALTERs. NULL means "not yet computed";
  readers decrypt those rows instead, and the `LinkResolutionKeys` data
  migration fills them.
  """

  def change do
    alter table(:notes) do
      add :path_ci_hmac, :binary
      add :path_length, :integer
    end

    alter table(:attachments) do
      add :path_ci_hmac, :binary
      add :path_length, :integer
    end

    alter table(:note_links) do
      add :target_key_hmac, :binary
    end
  end
end
