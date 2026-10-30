defmodule Engram.FolderRows do
  @moduledoc false
  # Raw superuser rows for the folders-table tests (the `folders` schema has
  # no writer in the app yet).
  alias Engram.Repo

  @doc "Inserts one folder row; returns its id. Opts: `:parent`, `:full_path_hmac`, `:deleted_at`."
  def insert!(user, vault, name_hmac, opts \\ []) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO folders (id, vault_id, user_id, parent_id, name_ciphertext, name_nonce,
                           name_hmac, full_path_hmac, dek_version, deleted_at)
      VALUES ($1, $2, $3, $4, '\\x00', '\\x00', $5, $6, 2, $7)
      """,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(vault.id),
        Ecto.UUID.dump!(user.id),
        opts[:parent] && Ecto.UUID.dump!(opts[:parent]),
        name_hmac,
        opts[:full_path_hmac],
        opts[:deleted_at]
      ]
    )

    id
  end
end
