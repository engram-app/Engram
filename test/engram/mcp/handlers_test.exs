defmodule Engram.MCP.HandlersTest do
  use Engram.DataCase, async: false

  alias Engram.Attachments
  alias Engram.MCP.Handlers
  alias Engram.MCP.Tools
  alias Engram.Notes

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)
    Mox.stub(Engram.MockStorage, :put, fn _key, _bin, _opts -> :ok end)
    Mox.stub(Engram.MockStorage, :delete, fn _key -> :ok end)

    user = insert(:user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  describe "rmw_upsert/4: locked read-modify-write" do
    # MCP write tools are read-modify-write: read → rebuild → upsert. A write
    # landing between the read and the upsert used to be silently deleted by
    # the full-content merge (2026-07-07: MCP appends erased). The read now
    # locks the row, so another transaction waits instead (see
    # HandlersSingleReadConcurrencyTest). A write from INSIDE the rebuild runs
    # in the same transaction and so is not blocked; the snapshot fence must
    # still refuse to overwrite it.
    test "a write landing inside the rebuild is refused, not overwritten", ctx do
      %{user: user, vault: vault} = ctx
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "r.md", "content" => "base", "mtime" => 1.0},
          actor: "api"
        )

      assert {:error, :version_conflict, _} =
               Handlers.rmw_upsert(user, vault, "r.md", fn content ->
                 {:ok, _} =
                   Notes.upsert_note(
                     user,
                     vault,
                     %{"path" => "r.md", "content" => "base\nconcurrent", "mtime" => 2.0},
                     actor: "api"
                   )

                 content <> "\nappended"
               end)

      {:ok, note} = Notes.get_note(user, vault, "r.md")
      assert {:ok, "base\nconcurrent"} = Notes.authoritative_content(user, note)
    end

    # append_to_note's position: start guard runs INSIDE the rebuild function
    # so it checks the locked content rmw_upsert actually rebuilds from, not a
    # snapshot read before the lock (a concurrent write could land in between
    # and slip an unsafe shape through).
    test "rebuild may refuse with {:error, msg} and nothing is written", ctx do
      %{user: user, vault: vault} = ctx
      alias Engram.Notes
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(
          user,
          vault,
          %{
            "path" => "refuse.md",
            "content" => "base",
            "mtime" => 1.0
          },
          actor: "api"
        )

      assert {:error, "nope"} =
               Handlers.rmw_upsert(user, vault, "refuse.md", fn _content -> {:error, "nope"} end)

      {:ok, note} = Notes.get_note(user, vault, "refuse.md")
      assert {:ok, "base"} = Notes.authoritative_content(user, note)
    end
  end

  describe "rename_folder handler" do
    test "cascades attachments and reports both counts", %{user: user, vault: vault} do
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "Docs/a.png",
          "content_base64" => Base.encode64("x")
        })

      assert {:ok, msg, _} =
               Handlers.handle("rename_folder", user, vault, %{
                 "old_folder" => "Docs",
                 "new_folder" => "Archive"
               })

      assert msg =~ "1 attachment"

      {:ok, metas} = Attachments.list_attachments(user, vault)
      assert Enum.map(metas, & &1.path) == ["Archive/a.png"]
    end
  end

  describe "move_attachment handler" do
    test "moves a single attachment", %{user: user, vault: vault} do
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "a.png",
          "content_base64" => Base.encode64("x")
        })

      assert {:ok, msg, _} =
               Handlers.handle("move_attachment", user, vault, %{
                 "old_path" => "a.png",
                 "new_path" => "img/a.png"
               })

      assert msg =~ "img/a.png"

      {:ok, metas} = Attachments.list_attachments(user, vault)
      assert Enum.map(metas, & &1.path) == ["img/a.png"]
    end

    test "move_attachment registered as a tool" do
      assert {:ok, %{name: "move_attachment"}} = Tools.get("move_attachment")
    end

    test "an unexpected crypto error returns a clean message, not a crash", %{
      user: user,
      vault: vault
    } do
      # Bug 2: move_attachment's crypto `with` head can return {:error, reason}
      # (e.g. an unrecognised DEK blob) that the handler used to leave unmatched
      # → CaseClauseError → 500. A corrupt encrypted_dek triggers
      # {:error, :unrecognised_blob} out of Crypto.get_dek/1.
      corrupt = user |> Ecto.Changeset.change(encrypted_dek: :crypto.strong_rand_bytes(32))
      {:ok, corrupt_user} = Engram.Repo.update(corrupt, skip_tenant_check: true)

      assert {:error, msg} =
               Handlers.handle("move_attachment", corrupt_user, vault, %{
                 "old_path" => "a.png",
                 "new_path" => "img/a.png"
               })

      assert msg =~ "Could not move attachment"

      # Still the point of this test: a reason from the crypto path can carry
      # decrypted struct fields, so it is logged, never rendered. It used to be
      # inspect/1'd straight into the body.
      refute msg =~ "unrecognised_blob"
    end
  end

  describe "rename_folder handler error path" do
    # Bug 2: Folders.rename's spec is {:ok, counts()} | {:error, term()} — it can
    # surface a non-:conflict {:error, reason} (the attachment leg's move can
    # return an arbitrary crypto error). The handler used to match only
    # {:ok,_}/:conflict, so any other error → CaseClauseError → 500. The
    # catch-all clause must exist and produce a clean user-facing message.
    test "the handler has a catch-all clause returning a clean message" do
      src = File.read!("lib/engram/mcp/handlers.ex")

      [_, rename_body | _] = String.split(src, ~r/def handle\("rename_folder"/)

      handler = rename_body |> String.split(~r/\n  def handle\(/) |> hd()

      assert handler =~ ~r/\{:error,\s*reason\}/,
             "rename_folder handler must catch a generic {:error, reason} " <>
               "(Bug 2) so a non-:conflict coordinator error doesn't 500"

      assert handler =~ "Could not rename folder"
    end
  end

  describe "get_notes handler" do
    test "batch-reads multiple notes in one call", %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "A.md", "content" => "alpha", "mtime" => 1.0},
          actor: "api"
        )

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "B.md", "content" => "beta", "mtime" => 1.0},
          actor: "api"
        )

      assert {:ok, body, _} =
               Handlers.handle("get_notes", user, vault, %{"paths" => ["A.md", "B.md"]})

      assert body =~ "alpha"
      assert body =~ "beta"
    end

    test "reports a missing path inline without failing the batch", %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "A.md", "content" => "alpha", "mtime" => 1.0},
          actor: "api"
        )

      assert {:ok, body, _} =
               Handlers.handle("get_notes", user, vault, %{"paths" => ["A.md", "gone.md"]})

      assert body =~ "alpha"
      assert body =~ "Note not found: gone.md"
    end

    test "rejects an empty paths list", %{user: user, vault: vault} do
      assert {:error, _} = Handlers.handle("get_notes", user, vault, %{"paths" => []})
    end

    test "rejects more than 20 paths", %{user: user, vault: vault} do
      paths = for i <- 1..21, do: "n#{i}.md"
      assert {:error, msg} = Handlers.handle("get_notes", user, vault, %{"paths" => paths})
      assert msg =~ "max 20"
    end

    # Element typing (`paths` is declared `array of string`) is enforced by the
    # dispatch-level schema validator before the handler runs — pinned in
    # `EngramWeb.McpControllerTest`, "get_notes with wrong-typed elements inside
    # a correctly-shaped array returns -32_602". The handler keeps only the two
    # checks the schema does not declare: minItems and maxItems.

    test "registered as a tool",
      do: assert({:ok, %{name: "get_notes"}} = Tools.get("get_notes"))
  end

  describe "delete_folder handler" do
    test "deletes an empty folder", %{user: user, vault: vault} do
      {:ok, _} = Notes.create_folder_marker(user, vault, "Empty")

      assert {:ok, msg, _} = Handlers.handle("delete_folder", user, vault, %{"folder" => "Empty"})
      assert msg =~ "Folder deleted: Empty"
    end

    test "refuses a non-empty folder and reports counts", %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/a.md", "content" => "x", "mtime" => 1.0},
          actor: "api"
        )

      # A refusal to act, not a completed delete (#1660). Reporting it as
      # success told the caller the folder was gone, so it never re-issued
      # with recursive: true.
      assert {:error, msg} = Handlers.handle("delete_folder", user, vault, %{"folder" => "Docs"})
      assert msg =~ "recursive: true"
      assert msg =~ "1 notes"
    end

    test "recursive deletes contents", %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/a.md", "content" => "x", "mtime" => 1.0},
          actor: "api"
        )

      assert {:ok, msg, _} =
               Handlers.handle("delete_folder", user, vault, %{
                 "folder" => "Docs",
                 "recursive" => true
               })

      assert msg =~ "Folder deleted: Docs"
      assert {:error, :not_found} = Notes.get_note(user, vault, "Docs/a.md")
    end

    test "refuses to delete the vault root", %{user: user, vault: vault} do
      assert {:error, msg} = Handlers.handle("delete_folder", user, vault, %{"folder" => ""})
      assert msg =~ "root"
    end

    test "registered as a tool",
      do: assert({:ok, %{name: "delete_folder"}} = Tools.get("delete_folder"))
  end

  describe "list_folder attachment visibility" do
    test "lists attachments alongside notes", %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Docs/a.md", "content" => "x", "mtime" => 1.0},
          actor: "api"
        )

      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "Docs/p.png",
          "content_base64" => Base.encode64("x")
        })

      assert {:ok, body, _structured} =
               Handlers.handle("list_folder", user, vault, %{"folder" => "Docs"})

      assert body =~ "Docs/a.md"
      assert body =~ "Docs/p.png"
      assert body =~ "(attachment)"
    end

    test "attachment listing is non-recursive", %{user: user, vault: vault} do
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "Docs/Sub/deep.png",
          "content_base64" => Base.encode64("x")
        })

      assert {:ok, body, _structured} =
               Handlers.handle("list_folder", user, vault, %{"folder" => "Docs"})

      refute body =~ "deep.png"
    end

    test "renders an attachments-only folder (no notes)", %{user: user, vault: vault} do
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "Docs/p.png",
          "content_base64" => Base.encode64("x")
        })

      assert {:ok, body, _structured} =
               Handlers.handle("list_folder", user, vault, %{"folder" => "Docs"})

      assert body =~ "Docs/p.png"
      assert body =~ "(attachment)"
      refute body =~ "No notes found"
    end
  end

  describe "list_folder subfolders (absorbs list_folders, #1660 3.5)" do
    test "reports direct subfolders; recursive reports every descendant with counts", %{
      user: user,
      vault: vault
    } do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      for p <- ["A/a.md", "A/B/b.md", "A/B/C/c.md", "Z/z.md"],
          do:
            {:ok, _} =
              Notes.upsert_note(user, vault, %{"path" => p, "content" => "x", "mtime" => 1.0},
                actor: "api"
              )

      {:ok, _, direct} = Handlers.handle("list_folder", user, vault, %{"folder" => "A"})
      assert Enum.map(direct["folders"], & &1["folder"]) == ["A/B"]

      {:ok, _, all} =
        Handlers.handle("list_folder", user, vault, %{"folder" => "", "recursive" => true})

      assert Enum.map(all["folders"], & &1["folder"]) |> Enum.sort() == ["A", "A/B", "A/B/C", "Z"]
      assert Enum.find(all["folders"], &(&1["folder"] == "A/B"))["count"] == 1
    end

    test "non-recursive root lists only top-level folders", %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      for p <- ["A/a.md", "A/B/b.md", "Z/z.md"],
          do:
            {:ok, _} =
              Notes.upsert_note(user, vault, %{"path" => p, "content" => "x", "mtime" => 1.0},
                actor: "api"
              )

      {:ok, _, root} = Handlers.handle("list_folder", user, vault, %{"folder" => ""})
      assert Enum.map(root["folders"], & &1["folder"]) |> Enum.sort() == ["A", "Z"]
    end

    test "a folder with no subfolders returns an empty folders list", %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "Leaf/a.md", "content" => "x", "mtime" => 1.0},
          actor: "api"
        )

      {:ok, _, structured} = Handlers.handle("list_folder", user, vault, %{"folder" => "Leaf"})
      assert structured["folders"] == []
    end

    test "renders subfolders in the text even when the folder has no direct notes or attachments",
         %{user: user, vault: vault} do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      for p <- ["A/a.md", "Z/z.md"],
          do:
            {:ok, _} =
              Notes.upsert_note(user, vault, %{"path" => p, "content" => "x", "mtime" => 1.0},
                actor: "api"
              )

      {:ok, body, structured} = Handlers.handle("list_folder", user, vault, %{"folder" => ""})

      assert structured["notes"] == []
      assert structured["attachments"] == []
      assert Enum.map(structured["folders"], & &1["folder"]) |> Enum.sort() == ["A", "Z"]

      assert body =~ "**Folder:** (root)"
      assert body =~ "**Subfolders:**"
      assert body =~ "| A | 1 |"
      assert body =~ "| Z | 1 |"
      refute body =~ "No notes found"
    end

    # `list_folders_with_counts/2` only returns a row for a folder that holds
    # a note DIRECTLY — an intermediate folder like "P" here has no row of
    # its own (only "P/Q" does), so deriving subfolders purely from existing
    # rows made "P" invisible at the root and its only note unreachable by
    # navigation.
    test "an intermediate folder with no direct notes is still a navigable child", %{
      user: user,
      vault: vault
    } do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "P/Q/x.md", "content" => "x", "mtime" => 1.0},
          actor: "api"
        )

      {:ok, _, root} = Handlers.handle("list_folder", user, vault, %{"folder" => ""})
      assert root["folders"] == [%{"folder" => "P", "count" => 0}]

      {:ok, _, p} = Handlers.handle("list_folder", user, vault, %{"folder" => "P"})
      assert p["folders"] == [%{"folder" => "P/Q", "count" => 1}]

      {:ok, _, all} =
        Handlers.handle("list_folder", user, vault, %{"folder" => "", "recursive" => true})

      assert all["folders"] == [
               %{"folder" => "P", "count" => 0},
               %{"folder" => "P/Q", "count" => 1}
             ]
    end

    test "prefix safety: a folder name is not a prefix match for a same-named sibling", %{
      user: user,
      vault: vault
    } do
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      for p <- ["A/a.md", "AB/b.md"],
          do:
            {:ok, _} =
              Notes.upsert_note(user, vault, %{"path" => p, "content" => "x", "mtime" => 1.0},
                actor: "api"
              )

      {:ok, _, direct} = Handlers.handle("list_folder", user, vault, %{"folder" => "A"})
      assert direct["folders"] == []
    end
  end
end
