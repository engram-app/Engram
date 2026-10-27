defmodule Engram.FolderRows do
  @moduledoc false
  # Raw superuser rows for the folders-table tests: seeding a folder without
  # the app's writer, and reading the table back (`tree/1`, `ref/2`, `row/1`).
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
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

  @doc "`folder_ref_id` of a `notes` / `attachments` row, as a UUID string (nil = none)."
  def ref(table, id) when table in ["notes", "attachments"] do
    %{rows: [[ref]]} =
      Repo.query!("SELECT folder_ref_id FROM #{table} WHERE id = $1", [Ecto.UUID.dump!(id)])

    ref && Ecto.UUID.load!(ref)
  end

  @doc "One folder row as a map (any state), or nil."
  def row(id) do
    case Repo.query!(
           "SELECT parent_id, explicit, deleted_at, delete_op_id FROM folders WHERE id = $1",
           [Ecto.UUID.dump!(id)]
         ) do
      %{rows: [[parent, explicit, deleted_at, op]]} ->
        %{
          parent_id: parent && Ecto.UUID.load!(parent),
          explicit: explicit,
          deleted_at: deleted_at,
          delete_op_id: op && Ecto.UUID.load!(op)
        }

      _ ->
        nil
    end
  end

  @doc """
  The user's LIVE folders as `path => %{id, explicit}`, names decrypted the way a
  reader will (so a wrong key or AAD fails here).
  """
  def tree(user) do
    {:ok, dek} = Crypto.get_dek(user)

    %{rows: rows} =
      Repo.query!(
        "SELECT id, parent_id, name_ciphertext, name_nonce, explicit FROM folders " <>
          "WHERE user_id = $1 AND deleted_at IS NULL",
        [Ecto.UUID.dump!(user.id)]
      )

    by_id =
      Map.new(rows, fn [id, parent, ct, nonce, explicit] ->
        id = Ecto.UUID.load!(id)
        {:ok, name} = Envelope.decrypt(ct, nonce, dek, Crypto.aad_for_row(:folders, :name, id))
        {id, %{name: name, parent: parent && Ecto.UUID.load!(parent), explicit: explicit}}
      end)

    path = fn path, id, self ->
      case by_id[id] do
        %{parent: nil, name: n} -> n
        %{parent: p, name: n} -> self.(path, p, self) <> "/" <> n
      end
    end

    Map.new(by_id, fn {id, f} -> {path.(path, id, path), %{id: id, explicit: f.explicit}} end)
  end
end
