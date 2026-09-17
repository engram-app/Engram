defmodule Engram.MCP.HandlersWriteContractTest do
  @moduledoc """
  #1660 completing the conversion: every write tool now declares an
  `outputSchema`, which is a promise to return `structuredContent` on every
  success — and therefore a promise that a failure is not a success.

  These handlers used to report failure AS success in ~25 places, most of them
  through one shared `upsert_reply/2`. A model reading `isError` could not tell
  a landed write from a version conflict, so it moved on instead of retrying.

  Asserts the failure branches specifically. The success branches are covered
  by the sweep in McpStructuredOutputTest and the broadcast suite; the failure
  branches are the ones nothing exercised, which is why they drifted.
  """
  use Engram.DataCase, async: true

  alias Engram.MCP.Handlers
  alias Engram.Notes

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp note!(user, vault, path, content) do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => path, "content" => content})
    :ok
  end

  describe "a write that did not happen is an error" do
    test "write_note refuses an oversized note", %{user: user, vault: vault} do
      # Was {:ok, "Error: note exceeds maximum size of 10MB"} — a refusal whose
      # own text said "Error:" while the envelope said success.
      big = String.duplicate("x", Notes.max_note_bytes() + 1)

      assert {:error, msg} =
               Handlers.handle("write_note", user, vault, %{"path" => "b.md", "content" => big})

      assert msg =~ "maximum size"
    end

    test "patch_note reports text it could not find", %{user: user, vault: vault} do
      :ok = note!(user, vault, "a.md", "hello")

      assert {:error, msg} =
               Handlers.handle("patch_note", user, vault, %{
                 "path" => "a.md",
                 "find" => "nope",
                 "replace" => "x"
               })

      assert msg =~ "Text not found"
    end

    test "patch_note reports a missing note", %{user: user, vault: vault} do
      assert {:error, msg} =
               Handlers.handle("patch_note", user, vault, %{
                 "path" => "gone.md",
                 "find" => "a",
                 "replace" => "b"
               })

      assert msg =~ "Note not found"
    end

    test "update_section reports a heading it could not find", %{user: user, vault: vault} do
      :ok = note!(user, vault, "a.md", "# A\n\nbody")

      assert {:error, msg} =
               Handlers.handle("update_section", user, vault, %{
                 "path" => "a.md",
                 "heading" => "Nope",
                 "content" => "x"
               })

      assert msg =~ "Heading not found"
    end

    test "rename_note reports a conflict", %{user: user, vault: vault} do
      :ok = note!(user, vault, "a.md", "a")
      :ok = note!(user, vault, "b.md", "b")

      assert {:error, msg} =
               Handlers.handle("rename_note", user, vault, %{
                 "old_path" => "a.md",
                 "new_path" => "b.md"
               })

      assert msg =~ "already taken"
    end

    test "move_attachment reports a missing attachment", %{user: user, vault: vault} do
      assert {:error, msg} =
               Handlers.handle("move_attachment", user, vault, %{
                 "old_path" => "gone.png",
                 "new_path" => "img/gone.png"
               })

      assert msg =~ "not found"
    end
  end

  describe "successes carry their payload" do
    test "append_to_note distinguishes created from appended", %{user: user, vault: vault} do
      assert {:ok, _, %{"path" => "new.md", "created" => true}} =
               Handlers.handle("append_to_note", user, vault, %{
                 "path" => "new.md",
                 "text" => "hi"
               })

      assert {:ok, _, %{"created" => false}} =
               Handlers.handle("append_to_note", user, vault, %{
                 "path" => "new.md",
                 "text" => "more"
               })
    end

    test "patch_note reports how many it replaced", %{user: user, vault: vault} do
      :ok = note!(user, vault, "a.md", "x x x")

      # occurrence defaults to 0, which is "the first one", not "all".
      assert {:ok, _, %{"replacements" => 1}} =
               Handlers.handle("patch_note", user, vault, %{
                 "path" => "a.md",
                 "find" => "x",
                 "replace" => "y"
               })

      assert {:ok, _, %{"replacements" => 2}} =
               Handlers.handle("patch_note", user, vault, %{
                 "path" => "a.md",
                 "find" => "x",
                 "replace" => "z",
                 "occurrence" => -1
               })
    end

    test "patch_note errors when the occurrence is past the last one", %{
      user: user,
      vault: vault
    } do
      :ok = note!(user, vault, "a.md", "x once")

      # `find` is present, so this missed the "Text not found" guard and fell
      # through to an upsert that rewrote the note with its own bytes and
      # reported success.
      assert {:error, msg} =
               Handlers.handle("patch_note", user, vault, %{
                 "path" => "a.md",
                 "find" => "x",
                 "replace" => "y",
                 "occurrence" => 9
               })

      assert msg =~ "Occurrence 9 not found"
    end

    test "delete_note says whether anything was there", %{user: user, vault: vault} do
      :ok = note!(user, vault, "a.md", "a")

      # The delete is idempotent and returns :ok either way; the handler used
      # to discard that and announce "Note deleted" regardless.
      assert {:ok, _, %{"deleted" => true}} =
               Handlers.handle("delete_note", user, vault, %{"path" => "a.md"})

      assert {:ok, _, %{"deleted" => false}} =
               Handlers.handle("delete_note", user, vault, %{"path" => "a.md"})
    end

    test "get_notes keeps a miss inline rather than failing the batch", %{
      user: user,
      vault: vault
    } do
      :ok = note!(user, vault, "a.md", "alpha")

      assert {:ok, _, %{"notes" => notes}} =
               Handlers.handle("get_notes", user, vault, %{"paths" => ["a.md", "gone.md"]})

      assert [%{"found" => true, "path" => "a.md"}, %{"found" => false, "path" => "gone.md"}] =
               notes
    end

    test "set_vault with no vault_id still carries the key", %{user: user, vault: vault} do
      assert {:ok, text, %{"vault" => nil}} = Handlers.handle("set_vault", user, [vault], %{})
      assert text =~ "no active-vault state"
    end
  end
end
