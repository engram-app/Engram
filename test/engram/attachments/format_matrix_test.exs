defmodule Engram.Attachments.FormatMatrixTest do
  @moduledoc """
  Every attachment operation against a content-format v1 row (whole object
  under the DEK) and a v2 row (segmented, per-file key). A v2 row reaching a
  code path written for v1 (the tombstone that hard-coded
  `encryption_version: 1` and copied a nil `content_nonce`) raised on every
  move; this runs each operation on both so the next such seam fails here.
  """
  # async: false: rotation swaps the Qdrant URL env; uploads use InMemory.
  use EngramWeb.ConnCase, async: false

  alias Engram.Attachments
  alias Engram.Attachments.Attachment
  alias Engram.Attachments.Uploads
  alias Engram.Crypto
  alias Engram.Crypto.UserDekRotation
  alias Engram.Repo
  alias Engram.Storage.InMemory

  setup %{conn: conn} do
    # Rotation scrolls Qdrant; nothing is indexed here.
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/scroll", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"result" => %{"points" => [], "next_page_offset" => nil}})
      )
    end)

    # Real ciphertext vault name: rotation decrypts it.
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    insert(:subscription, user: user, tier: "pro", status: "active")
    vault = Engram.Fixtures.insert_vault!(user, "Matrix")
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "matrix")
    lift_api_rps_cap!(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key}")
      |> put_req_header("x-vault-id", vault.id)

    %{conn: conn, user: user, vault: vault}
  end

  defp put_row(user, vault, :v1, path, bytes) do
    {:ok, att} = Attachments.upsert_attachment(user, vault, %{path: path, content: bytes})
    att
  end

  defp put_row(user, vault, :v2, path, bytes) do
    {:ok, up} = Uploads.start(user, vault, %{path: path, size_bytes: byte_size(bytes)})
    {:ok, _} = Uploads.put_part(user, vault, up.id, 1, bytes)
    {:ok, att} = Uploads.complete(user, vault, up.id)
    att
  end

  defp download(user, vault, path) do
    case Attachments.get_attachment(Crypto.fresh_user(user), vault, path) do
      {:ok, nil} ->
        nil

      {:ok, %{content: {:segments, stream}}} ->
        stream |> Enum.map(fn {:ok, b} -> b end) |> IO.iodata_to_binary()

      {:ok, %{content: bytes}} ->
        bytes
    end
  end

  defp live_paths(user, vault) do
    {:ok, atts} = Attachments.list_attachments(Crypto.fresh_user(user), vault)
    atts |> Enum.map(& &1.path) |> Enum.sort()
  end

  for format <- [:v1, :v2] do
    describe "#{format} row" do
      setup %{user: user, vault: vault} do
        bytes = :crypto.strong_rand_bytes(100)
        att = put_row(user, vault, unquote(format), "f/a.png", bytes)
        assert att.encryption_version == if(unquote(format) == :v1, do: 1, else: 2)
        %{bytes: bytes, att: att}
      end

      test "move_attachment", %{user: user, vault: vault, bytes: bytes} do
        assert {:ok, _} = Attachments.move_attachment(user, vault, "f/a.png", "f/b.png")
        assert download(user, vault, "f/b.png") == bytes
        assert download(user, vault, "f/a.png") == nil
      end

      test "rename over HTTP", %{conn: conn, user: user, vault: vault, bytes: bytes} do
        conn = post(conn, "/api/attachments/rename", %{old_path: "f/a.png", new_path: "f/c.png"})
        assert %{"renamed" => true} = json_response(conn, 200)
        assert download(user, vault, "f/c.png") == bytes
      end

      test "rename_folder", %{user: user, vault: vault, bytes: bytes} do
        assert {:ok, _} = Attachments.rename_folder(user, vault, "f", "g")
        assert download(user, vault, "g/a.png") == bytes
        assert live_paths(user, vault) == ["g/a.png"]
      end

      test "batch_move", %{user: user, vault: vault, bytes: bytes} do
        assert {:ok, %{moved: 1}} = Attachments.batch_move(user, vault, ["f/a.png"], "h")
        assert download(user, vault, "h/a.png") == bytes
      end

      test "delete_attachment", %{user: user, vault: vault, att: att} do
        assert :ok = Attachments.delete_attachment(user, vault, "f/a.png")
        assert download(user, vault, "f/a.png") == nil
        refute InMemory.exists?(att.storage_key)
      end

      test "batch_delete", %{user: user, vault: vault, att: att} do
        assert {:ok, %{deleted: 1}} = Attachments.batch_delete(user, vault, ["f/a.png"])
        assert live_paths(user, vault) == []
        refute InMemory.exists?(att.storage_key)
      end

      test "delete_folder", %{user: user, vault: vault, att: att} do
        assert {:ok, _} = Attachments.delete_folder(user, vault, "f")
        assert live_paths(user, vault) == []
        refute InMemory.exists?(att.storage_key)
      end

      test "list", %{user: user, vault: vault} do
        assert live_paths(user, vault) == ["f/a.png"]
      end

      test "changes feed after a move", %{user: user, vault: vault, bytes: bytes} do
        {:ok, _} = Attachments.move_attachment(user, vault, "f/a.png", "f/b.png")
        {:ok, %{changes: changes}} = Attachments.list_changes_by_seq(user, vault, 0)

        assert changes |> Enum.map(&{&1.path, &1.deleted}) |> Enum.sort() ==
                 [{"f/a.png", true}, {"f/b.png", false}]

        assert download(user, vault, "f/b.png") == bytes
      end

      test "raw and JSON show", %{conn: conn, bytes: bytes} do
        assert conn |> get("/api/attachments/f/a.png?raw=1") |> response(200) == bytes

        assert %{"content_base64" => b64} =
                 conn |> get("/api/attachments/f/a.png") |> json_response(200)

        assert Base.decode64!(b64) == bytes
      end

      test "DEK rotation, then a move", %{user: user, vault: vault, bytes: bytes, att: att} do
        assert :ok = UserDekRotation.rotate_user(user.id)
        assert download(user, vault, "f/a.png") == bytes

        assert {:ok, _} = Attachments.move_attachment(user, vault, "f/a.png", "f/b.png")
        assert download(user, vault, "f/b.png") == bytes

        row = Repo.get!(Attachment, att.id, skip_tenant_check: true)
        assert row.encryption_version == att.encryption_version
      end
    end
  end
end
