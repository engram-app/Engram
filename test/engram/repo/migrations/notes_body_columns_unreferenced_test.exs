defmodule Engram.Repo.Migrations.NotesBodyColumnsUnreferencedTest do
  @moduledoc """
  R8(d): no database object names `notes.content_ciphertext` or
  `notes.crdt_state_ciphertext` any more (migration 20261111000100), so
  release E can drop them without breaking the shape check or the head
  trigger. Before it, a plain drop of the CRDT column failed (the trigger
  depended on it) and a drop of the content column took the whole shape
  check with it.
  """
  use Engram.DataCase, async: false

  alias Engram.Notes
  alias Engram.Repo

  setup do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "x\n", "mtime" => 1.0},
        actor: "api"
      )

    %{user: user, vault: vault, note: note, id: Ecto.UUID.dump!(note.id)}
  end

  defp shape_checks do
    Repo.query!("""
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.notes'::regclass AND conname LIKE 'notes_kind_shape%'
    """).rows
    |> List.flatten()
  end

  defp head_triggers do
    Repo.query!("""
    SELECT tgname FROM pg_trigger
    WHERE tgrelid = 'public.notes'::regclass AND tgname = 'notes_crdt_head_invalidate'
      AND NOT tgisinternal
    """).rows
    |> List.flatten()
  end

  test "both columns drop with RESTRICT, and the shape check and head trigger survive" do
    # In a savepoint: the rollback undoes the drop and releases its lock.
    assert {:error, :rolled_back} =
             Repo.transaction(fn ->
               Repo.query!("ALTER TABLE notes DROP COLUMN crdt_state_ciphertext RESTRICT")
               Repo.query!("ALTER TABLE notes DROP COLUMN content_ciphertext RESTRICT")
               assert shape_checks() == ["notes_kind_shape_v4_check"]
               assert head_triggers() == ["notes_crdt_head_invalidate"]
               Repo.rollback(:rolled_back)
             end)
  end

  test "a CRDT nonce change resets the head; a ciphertext-only change does not", ctx do
    head = String.duplicate("A", 43)
    head_of = fn -> Repo.query!("SELECT crdt_head FROM notes WHERE id = $1", [ctx.id]).rows end

    set_head = fn ->
      Repo.query!("UPDATE notes SET crdt_head = $2 WHERE id = $1", [ctx.id, head])
    end

    set_head.()

    Repo.query!("UPDATE notes SET crdt_state_ciphertext = $2 WHERE id = $1", [
      ctx.id,
      :crypto.strong_rand_bytes(32)
    ])

    assert head_of.() == [[head]]

    Repo.query!("UPDATE notes SET crdt_state_nonce = $2 WHERE id = $1", [
      ctx.id,
      <<1>> <> :crypto.strong_rand_bytes(12)
    ])

    assert head_of.() == [[nil]]

    # NULL to a nonce (a pre-nonce row's first write) is a change too.
    Repo.query!("UPDATE notes SET crdt_state_nonce = NULL WHERE id = $1", [ctx.id])
    set_head.()

    Repo.query!("UPDATE notes SET crdt_state_nonce = $2 WHERE id = $1", [
      ctx.id,
      <<1>> <> :crypto.strong_rand_bytes(12)
    ])

    assert head_of.() == [[nil]]
  end

  test "a note needs no notes body column; the rest of the shape still holds", ctx do
    assert {:ok, _} =
             Repo.query(
               "UPDATE notes SET content_ciphertext = NULL, content_nonce = NULL WHERE id = $1",
               [ctx.id],
               mode: :savepoint
             )

    for set <- ["path_hmac = NULL", "title_ciphertext = NULL", "tags_ciphertext = NULL"] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
               Repo.query("UPDATE notes SET #{set} WHERE id = $1", [ctx.id], mode: :savepoint),
             set
    end

    {:ok, marker} = Notes.create_folder_marker(ctx.user, ctx.vault, "M")
    marker_id = Ecto.UUID.dump!(marker.id)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             Repo.query("UPDATE notes SET folder_hmac = NULL WHERE id = $1", [marker_id],
               mode: :savepoint
             )
  end

  # The migration runs at boot. A checkout without `timeout: :infinity` gets
  # DBConnection's 15 s deadline for the whole block (VALIDATE scan included),
  # which crashed the 0.79.0 boot. Read the source: the deadline only bites on
  # a prod-sized table, so a behavioural test here would pass either way. The
  # checkout lives in the shared helper the migration runs through.
  test "the migration's checkout has no 15 s deadline" do
    assert File.read!(
             "priv/repo/migrations/20261111000100_notes_body_columns_unreferenced_expand.exs"
           ) =~ "LockTimeoutRetry.with_lock_timeout(repo"

    {:ok, ast} =
      "priv/repo/migrations/lock_timeout_retry.exs"
      |> File.read!()
      |> Code.string_to_quoted()

    {_, opts} =
      Macro.prewalk(ast, [], fn
        {{:., _, [_, :checkout]}, _, args} = node, acc -> {node, [Enum.drop(args, 1) | acc]}
        node, acc -> {node, acc}
      end)

    assert opts != []
    assert Enum.all?(opts, &(&1 == [[timeout: :infinity]]))
  end
end
