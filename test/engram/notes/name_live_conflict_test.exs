defmodule Engram.Notes.NameLiveConflictTest do
  # Release L's `notes_name_live` refuses a second live note at a folder row
  # and exact name, including where no path lookup sees the holder (its name
  # keys are stale: here a note at F/a.md whose `name_hmac` still says x.md).
  # Clients key on today's refusal codes (the web app name-bumps a create on
  # the wire's `create_failed`, shows "already exists" on a REST 409), so a
  # refusal by the new index must reach every surface EXACTLY as a path index
  # refusal of the same operation does: each test runs both and compares the
  # replies (review H1). The crdt wire's create is in
  # crdt_create_name_conflict_test.exs.
  use EngramWeb.ConnCase, async: false

  alias Engram.{Fixtures, Folders, Notes, Repo}
  alias Engram.MCP.Handlers

  setup :authed_api_conn

  setup %{user: user, vault: vault} do
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    holder = note!(user, vault, "F/a.md")
    Fixtures.stale_name_holder!(user, vault, holder, "F/x.md")
    on_exit(fn -> Application.delete_env(:engram, :checkpoint_interleave_hook) end)
    %{user: user, holder: holder}
  end

  defp note!(u, v, path) do
    {:ok, note} =
      Notes.upsert_note(u, v, %{"path" => path, "content" => "# #{path}"}, actor: "api")

    note
  end

  defp live?(u, v, path), do: match?({:ok, _}, Notes.get_note(u, v, path))

  # A path index refusal: a note's write through `Note.changeset/2` onto a
  # path another live note holds (`notes_path_live`), the changeset error
  # every create and move surface already maps.
  defp path_refusal(u, v) do
    a = note!(u, v, "F/p.md")
    b = note!(u, v, "F/q.md")

    {:error, cs} =
      Repo.with_tenant(u.id, fn ->
        Notes.Note
        |> Repo.get!(b.id)
        |> Notes.Note.changeset(%{path_hmac: path_hmac(a), content_ciphertext: "x"})
        # In a savepoint: the refusal must not abort the tenant transaction.
        |> Repo.update(mode: :savepoint)
      end)
      |> elem(1)

    cs
  end

  defp path_hmac(note) do
    %{rows: [[h]]} =
      Repo.query!("SELECT path_hmac FROM notes WHERE id = $1", [Ecto.UUID.dump!(note.id)])

    h
  end

  defp refusal(%{errors: errors}),
    do: for({field, {msg, opts}} <- errors, do: {field, msg, opts[:constraint]})

  describe "create" do
    test "the same changeset refusal as a path index's", %{user: u, vault: v} do
      assert {:error, %Ecto.Changeset{} = by_name} =
               Notes.upsert_note(u, v, %{"path" => "F/x.md", "content" => "y"}, actor: "api")

      assert refusal(by_name) == refusal(path_refusal(u, v))
      assert live?(u, v, "F/a.md")
    end

    test "REST: the status and body of a path index refusal", %{conn: conn, user: u, vault: v} do
      by_name = post(conn, ~p"/api/notes", %{"path" => "F/x.md", "content" => "y"})

      assert json_response(by_name, 422) ==
               Jason.decode!(
                 Jason.encode!(%{errors: EngramWeb.format_errors(path_refusal(u, v))})
               )
    end
  end

  describe "note rename" do
    test "the same conflict as a taken path", %{user: u, vault: v} do
      note!(u, v, "F/b.md")
      note!(u, v, "F/p.md")

      assert {:error, :conflict} = Notes.rename_note(u, v, "F/b.md", "F/p.md")
      assert {:error, :conflict} = Notes.rename_note(u, v, "F/b.md", "F/x.md")
      assert live?(u, v, "F/b.md")
    end

    test "REST: the same status and body", %{conn: conn, user: u, vault: v} do
      note!(u, v, "F/b.md")
      note!(u, v, "F/p.md")
      rename = &post(conn, ~p"/api/notes/rename", %{"old_path" => "F/b.md", "new_path" => &1})

      by_path = rename.("F/p.md")
      by_name = rename.("F/x.md")
      assert by_path.status == 409
      assert by_name.status == by_path.status
      assert json_response(by_name, 409) == json_response(by_path, 409)
    end

    test "MCP: the same reply", %{user: u, vault: v} do
      note!(u, v, "F/b.md")
      note!(u, v, "F/p.md")
      args = &%{"old_path" => "F/b.md", "new_path" => &1}

      assert {:error, {code, _}} = Handlers.handle("rename_note", u, v, args.("F/p.md"))
      assert {:error, {^code, _}} = Handlers.handle("rename_note", u, v, args.("F/x.md"))
    end
  end

  describe "folder rename" do
    # The cascade's checks leave no natural way to reach the write-time
    # backstop, so the hook raises the index's violation from inside the
    # transaction, as nested_collision_test.exs does for the path indexes.
    defp raise_at_seal(constraint) do
      Application.put_env(:engram, :checkpoint_interleave_hook, fn
        :folder_rename_seal ->
          raise %Postgrex.Error{
            postgres: %{
              code: :unique_violation,
              pg_code: "23505",
              constraint: constraint,
              severity: "ERROR",
              message: "dup"
            }
          }

        _ ->
          :ok
      end)
    end

    test "the same conflict as a path index's", %{user: u, vault: v} do
      raise_at_seal("notes_path_live")
      by_path = Folders.rename(u, v, "F", "G")
      raise_at_seal("notes_name_live")
      assert Folders.rename(u, v, "F", "G") == by_path
      assert by_path == {:error, :conflict}
      assert live?(u, v, "F/a.md")
    end

    test "REST: the same status and body", %{conn: conn} do
      rename = fn ->
        post(conn, ~p"/api/folders/rename", %{"old_path" => "F", "new_path" => "G"})
      end

      raise_at_seal("notes_path_live")
      by_path = rename.()
      raise_at_seal("notes_name_live")
      by_name = rename.()

      assert by_name.status == by_path.status
      assert json_response(by_name, by_name.status) == json_response(by_path, by_path.status)
    end
  end
end
