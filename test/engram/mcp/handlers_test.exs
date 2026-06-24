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
  end
end
