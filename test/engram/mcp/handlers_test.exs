defmodule Engram.MCP.HandlersTest do
  use Engram.DataCase, async: false

  alias Engram.Attachments
  alias Engram.MCP.Handlers

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

  describe "rmw_upsert/4 — read-modify-write CAS (Phase 0)" do
    # MCP write tools are read-modify-write: get_note → rebuild → upsert. A
    # write landing between the read and the upsert used to be silently
    # deleted by the full-content merge (the rebuilt content is diffed against
    # the moved row — 2026-07-07: MCP appends erased). rmw_upsert declares the
    # read hash as base_hash and retries once on the resulting conflict.
    test "retries once when the row moves between read and write", ctx do
      %{user: user, vault: vault} = ctx
      alias Engram.Notes
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "r.md", "content" => "base", "mtime" => 1.0})

      raced = :counters.new(1, [])

      {:ok, note} =
        Handlers.rmw_upsert(user, vault, "r.md", fn content ->
          # First rebuild simulates the race: a concurrent writer moves the row
          # AFTER our read, BEFORE our upsert.
          if :counters.get(raced, 1) == 0 do
            :counters.add(raced, 1, 1)

            {:ok, _} =
              Notes.upsert_note(user, vault, %{
                "path" => "r.md",
                "content" => "base\nconcurrent",
                "mtime" => 2.0
              })
          end

          content <> "\nappended"
        end)

      # Neither write lost: the retry re-read the moved row and rebuilt on it.
      assert note.content =~ "concurrent"
      assert note.content =~ "appended"
    end

    test "gives up with an error after the retry also conflicts", ctx do
      %{user: user, vault: vault} = ctx
      alias Engram.Notes
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "g.md", "content" => "base", "mtime" => 1.0})

      tick = :counters.new(1, [])

      assert {:error, :version_conflict, _} =
               Handlers.rmw_upsert(user, vault, "g.md", fn content ->
                 # EVERY rebuild races — the row moves each time, so the retry
                 # conflicts too and the helper must stop rather than loop.
                 n = :counters.get(tick, 1)
                 :counters.add(tick, 1, 1)

                 {:ok, _} =
                   Notes.upsert_note(user, vault, %{
                     "path" => "g.md",
                     "content" => "base\nconcurrent#{n}",
                     "mtime" => 2.0 + n
                   })

                 content <> "\nappended"
               end)
    end
  end

  describe "rename_folder handler" do
    test "cascades attachments and reports both counts", %{user: user, vault: vault} do
      {:ok, _} =
        Attachments.upsert_attachment(user, vault, %{
          "path" => "Docs/a.png",
          "content_base64" => Base.encode64("x")
        })

      assert {:ok, msg} =
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

      assert {:ok, msg} =
               Handlers.handle("move_attachment", user, vault, %{
                 "old_path" => "a.png",
                 "new_path" => "img/a.png"
               })

      assert msg =~ "img/a.png"

      {:ok, metas} = Attachments.list_attachments(user, vault)
      assert Enum.map(metas, & &1.path) == ["img/a.png"]
    end

    test "move_attachment registered as a tool" do
      assert {:ok, %{name: "move_attachment"}} = Engram.MCP.Tools.get("move_attachment")
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

      assert {:ok, msg} =
               Handlers.handle("move_attachment", corrupt_user, vault, %{
                 "old_path" => "a.png",
                 "new_path" => "img/a.png"
               })

      assert msg =~ "Could not move attachment"
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
end
