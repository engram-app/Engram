defmodule Engram.Notes.NameKeyTriggerTest do
  # `notes_set_name_key` (20261113100000) keeps `notes.name_key`, the S3
  # name lookup's stored key (`name_ci_hmac || uuid_send(folder_ref_id)`),
  # for every writer, and NULL unless the name keys are current.
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Crypto.NameKeys
  alias Engram.Notes
  alias Engram.Repo

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp note!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "x"}, actor: "api")

    note
  end

  defp row(id) do
    %{rows: [[key, ci, ref]]} =
      Repo.query!("SELECT name_key, name_ci_hmac, folder_ref_id FROM notes WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    {key, ci, ref}
  end

  test "a note in a folder carries its name and folder row", %{user: u, vault: v} do
    note = note!(u, v, "A/B/x.md")
    {key, ci, ref} = row(note.id)
    assert is_binary(ci) and is_binary(ref)
    assert key == ci <> ref
  end

  test "a root note has none", %{user: u, vault: v} do
    assert {nil, _, nil} = row(note!(u, v, "top.md").id)
  end

  test "a stale name stamp clears it, a fresh one sets it again", %{user: u, vault: v} do
    note = note!(u, v, "A/x.md")
    {key, _, _} = row(note.id)
    assert is_binary(key)

    Repo.query!("UPDATE notes SET name_stamp = '\\x00'::bytea WHERE id = $1", [
      Ecto.UUID.dump!(note.id)
    ])

    assert {nil, _, _} = row(note.id)

    Repo.query!(
      "UPDATE notes SET name_stamp = path_nonce || $2::bytea WHERE id = $1",
      [Ecto.UUID.dump!(note.id), NameKeys.version()]
    )

    assert {^key, _, _} = row(note.id)
  end

  test "the folder row's release clears it", %{user: u, vault: v} do
    note = note!(u, v, "A/x.md")

    Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [
      Ecto.UUID.dump!(note.id)
    ])

    assert {nil, _, nil} = row(note.id)
  end

  # `notes_folder_ref_live_only` blanks `folder_ref_id` on a restore whose
  # folder row is trashed. A restore that names only `deleted_at` must still
  # recompute the key, or a revived folder row would match it by name.
  test "a restore into a trashed folder row clears it", %{user: u, vault: v} do
    note = note!(u, v, "A/x.md")
    {key, _, ref} = row(note.id)
    assert is_binary(key)
    id = Ecto.UUID.dump!(note.id)

    Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [id])
    Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [ref])
    Repo.query!("UPDATE notes SET deleted_at = NULL WHERE id = $1", [id])

    assert {nil, _, nil} = row(note.id)
  end

  # The trigger inlines the stamp's version byte: a bump of
  # `NameKeys.version/0` must ship a new trigger, or no name would match.
  test "the trigger's stamp version is NameKeys.version/0" do
    %{rows: [[src]]} =
      Repo.query!("SELECT prosrc FROM pg_proc WHERE proname = 'notes_set_name_key'")

    assert src =~ "'\\x#{Base.encode16(NameKeys.version(), case: :lower)}'::bytea"
  end
end
