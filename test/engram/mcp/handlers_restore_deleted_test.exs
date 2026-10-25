defmodule Engram.MCP.HandlersRestoreDeletedTest do
  @moduledoc """
  Safer delete (#609): every MCP delete returns a `delete_op_id` and when it
  stops being restorable, and `restore_deleted` undoes it in one call. On
  2026-10-24 an agent's `delete_folder` removed 7,440 attachments and only
  S3 versioning saved the blobs (#2159).
  """
  use Engram.DataCase, async: false

  alias Engram.{Attachments, Notes}
  alias Engram.MCP.{Handlers, Tools}

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp put_note(user, vault, path, content \\ "x") do
    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")
  end

  defp put_att(user, vault, path) do
    {:ok, _} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("x")
      })
  end

  defp restore(user, vault, op),
    do: Handlers.handle("restore_deleted", user, vault, %{"op_id" => op})

  defp assert_restorable_until(iso) do
    {:ok, until, 0} = DateTime.from_iso8601(iso)
    # Free keeps trash 7 days.
    assert DateTime.diff(until, DateTime.utc_now(), :day) in 6..7
  end

  test "delete_note returns an op id that restore_deleted undoes", %{user: user, vault: vault} do
    put_note(user, vault, "a.md")

    assert {:ok, text, %{"deleted" => true, "delete_op_id" => op, "restorable_until" => until}} =
             Handlers.handle("delete_note", user, vault, %{"path" => "a.md"})

    assert text =~ "trash"
    assert_restorable_until(until)
    assert {:error, :not_found} = Notes.get_note(user, vault, "a.md")

    assert {:ok, _text, %{"notes" => 1, "attachments" => 0, "skipped" => []}} =
             restore(user, vault, op)

    assert {:ok, _} = Notes.get_note(user, vault, "a.md")

    # Idempotent: a second call restores nothing and still succeeds.
    assert {:ok, _text, %{"notes" => 0}} = restore(user, vault, op)
  end

  test "an absent delete returns no op id", %{user: user, vault: vault} do
    assert {:ok, _text, %{"deleted" => false, "delete_op_id" => nil}} =
             Handlers.handle("delete_note", user, vault, %{"path" => "nope.md"})
  end

  test "delete_folder recursive is undone in one call", %{user: user, vault: vault} do
    put_note(user, vault, "Docs/a.md")
    put_att(user, vault, "Docs/a.png")

    assert {:ok, _text, %{"notes" => 1, "attachments" => 1, "delete_op_id" => op}} =
             Handlers.handle("delete_folder", user, vault, %{
               "folder" => "Docs",
               "recursive" => true
             })

    assert {:ok, _text, %{"notes" => 1, "attachments" => 1}} = restore(user, vault, op)
    assert {:ok, _} = Notes.get_note(user, vault, "Docs/a.md")
    assert {:ok, [%{path: "Docs/a.png"}]} = Attachments.list_attachments(user, vault)
  end

  test "delete_attachment returns an op id", %{user: user, vault: vault} do
    put_att(user, vault, "a.png")

    assert {:ok, _text, %{"deleted" => true, "delete_op_id" => op}} =
             Handlers.handle("delete_attachment", user, vault, %{"path" => "a.png"})

    assert {:ok, _text, %{"attachments" => 1}} = restore(user, vault, op)
  end

  test "a skipped path is reported in text and payload", %{user: user, vault: vault} do
    put_note(user, vault, "a.md")

    {:ok, _, %{"delete_op_id" => op}} =
      Handlers.handle("delete_note", user, vault, %{"path" => "a.md"})

    put_note(user, vault, "a.md", "a different note")

    assert {:ok, text, %{"notes" => 0, "skipped" => [skip]}} = restore(user, vault, op)
    assert skip == %{"path" => "a.md", "kind" => "note", "reason" => "path_taken"}
    assert text =~ "a.md"
  end

  test "a malformed op id is an invalid-arguments error", %{user: user, vault: vault} do
    assert {:error, {:invalid_arguments, _}} = restore(user, vault, "nope")
  end

  test "past notes_cap the restore is refused with the cap code", %{user: user, vault: vault} do
    insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => 1})
    put_note(user, vault, "a.md")

    {:ok, _, %{"delete_op_id" => op}} =
      Handlers.handle("delete_note", user, vault, %{"path" => "a.md"})

    put_note(user, vault, "b.md")

    assert {:error, {:notes_cap_exceeded, msg}} = restore(user, vault, op)
    assert msg =~ "notes_cap"
  end

  test "restore_deleted is a non-destructive, idempotent write tool" do
    assert {:ok, tool} = Tools.get("restore_deleted")
    assert tool.annotations["readOnlyHint"] == false
    assert tool.annotations["destructiveHint"] == false
    assert tool.annotations["idempotentHint"] == true
    assert Tools.writes_vault?("restore_deleted")
  end

  test "delete tools no longer say permanent" do
    for name <- ~w(delete_note delete_folder delete_attachment) do
      {:ok, tool} = Tools.get(name)
      refute tool.description =~ ~r/permanent|cannot be restored/i, name
      assert tool.description =~ "restore_deleted", name
    end
  end
end
