defmodule EngramWeb.VaultTreeControllerTest do
  use EngramWeb.ConnCase, async: true

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Engram.Attachments.Attachment
  alias Engram.TenantQueryCounter

  setup %{conn: conn} do
    user = insert(:user)
    insert(:subscription, user: user, tier: "pro", status: "active")
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)
    authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
    %{conn: authed, user: user, vault: vault}
  end

  # Counts `with_tenant/2` invocations that actually open a transaction —
  # see Engram.TenantQueryCounter (#1211 regression guard, shared with
  # SyncControllerTest and RepoTenantRoundtripsTest).
  defp count_tenant_enters(fun), do: TenantQueryCounter.count_tenant_enters(fun)

  describe "GET /vault/tree with_tenant round trips" do
    # Floor is 2, not 1: EngramWeb.Plugs.VaultPlug resolves `current_vault`
    # (Vaults.get_default_vault/1) in its own with_tenant block before the
    # controller action runs, on every authed API request — same reasoning
    # as SyncControllerTest's equivalent guard for #1211. Only the
    # controller-owned blocks (current_seq + notes + folder counts + folder
    # markers + attachments — 5 of them) are being collapsed, into 1.
    test "a populated tree opens at most 2 with_tenant blocks", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/A.md", content: "# A", mtime: 1_000.0})

      post(conn, "/api/attachments", %{
        path: "img.png",
        content_base64: Base.encode64("hi"),
        mtime: 1_000.0
      })

      enters =
        count_tenant_enters(fn ->
          conn |> get("/api/vault/tree") |> json_response(200)
        end)

      assert length(enters) <= 2,
             "expected at most 2 with_tenant blocks (VaultPlug + one combined " <>
               "seq/notes/folders/attachments fetch), got #{length(enters)}: #{inspect(enters)}"
    end
  end

  describe "GET /vault/tree" do
    test "returns an empty tree for a new user", %{conn: conn} do
      # insert(:user) provisions no DEK, so this exercises the
      # {:error, :no_dek} branch of show/2 (the hardcoded empty_tree/1
      # literal), NOT render_tree/5. See the DEK-provisioned companion test
      # below for coverage of render_tree/5 on an empty vault.
      body = conn |> get("/api/vault/tree") |> json_response(200)

      assert body["notes"] == []
      assert body["folders"] == []
      assert body["attachments"] == []
      assert body["change_seq"] == 0
    end

    test "returns an empty tree for a DEK-provisioned user with no notes" do
      # insert_user/1 runs Crypto.ensure_user_dek/1, so this request takes
      # the {:ok, dek} branch and actually runs render_tree/5's queries +
      # folders_payload/2 against zero rows, instead of short-circuiting to
      # the hardcoded empty_tree/1 literal like the test above.
      user = insert_user()
      insert(:subscription, user: user, tier: "pro", status: "active")
      insert(:vault, user: user, is_default: true)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "dek-test-key")
      grant_api_write!(user)
      conn = build_conn() |> put_req_header("authorization", "Bearer #{api_key}")

      body = conn |> get("/api/vault/tree") |> json_response(200)

      assert body["notes"] == []
      assert body["folders"] == []
      assert body["attachments"] == []
      assert body["change_seq"] == 0
    end

    test "returns every note with id, path and both timestamps", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/A.md", content: "# Alpha", mtime: 1_000.0})
      post(conn, "/api/notes", %{path: "Test/B.md", content: "# Beta", mtime: 1_000.0})

      body = conn |> get("/api/vault/tree") |> json_response(200)

      assert length(body["notes"]) == 2
      note = Enum.find(body["notes"], &(&1["path"] == "Test/A.md"))
      assert note["id"]
      assert note["created_at"]
      assert note["updated_at"]
    end

    test "returns every attachment with id, path, mime_type, size_bytes, mtime and updated_at", %{
      conn: conn
    } do
      post(conn, "/api/attachments", %{
        path: "img.png",
        content_base64: Base.encode64("hi"),
        mtime: 1_709_234_567.0
      })

      body = conn |> get("/api/vault/tree") |> json_response(200)

      assert [att] = body["attachments"]
      assert att["path"] == "img.png"
      assert att["mime_type"] == "image/png"
      assert att["size_bytes"] == 2
      # loader.ts sorts attachments by mtime under "modified-*" sort — must be
      # the real value, not a placeholder, or seeded and fetched rows diverge.
      assert att["mtime"] == 1_709_234_567.0
      # use-engram-tree.ts's attachmentsFingerprint reads updated_at to decide
      # whether to rebuild the tree — a seeded placeholder here collapses that
      # signal, same reasoning as mtime above.
      assert att["updated_at"]
    end

    test "returns folders derived from note paths, with note counts", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Test/A.md", content: "# Alpha", mtime: 1_000.0})

      body = conn |> get("/api/vault/tree") |> json_response(200)
      folder = Enum.find(body["folders"], &(&1["name"] == "Test"))

      assert %{"name" => "Test", "count" => 1} = folder
    end

    test "omits folder marker rows from notes", %{conn: conn, user: user, vault: vault} do
      # Marker rows (kind="folder") have path_ciphertext=nil; if the notes
      # query doesn't filter by kind == "note", PathCrypto.decrypt!/4 raises
      # on the nil ciphertext and the whole tree 500s. Ported from
      # SyncController's "omits folder marker rows" test.
      {:ok, _marker} = Engram.Notes.create_folder_marker(user, vault, "EmptyFolder")
      post(conn, "/api/notes", %{path: "Real.md", content: "# real", mtime: 1_000.0})

      body = conn |> get("/api/vault/tree") |> json_response(200)

      assert Enum.map(body["notes"], & &1["path"]) == ["Real.md"]
    end

    test "omits the fields the tree never reads", %{conn: conn} do
      post(conn, "/api/notes", %{path: "A.md", content: "# A", mtime: 1_000.0})

      body = conn |> get("/api/vault/tree") |> json_response(200)
      note = hd(body["notes"])

      # These are the ~128 bytes/note that disqualified reusing the manifest.
      refute Map.has_key?(note, "content_hash")
      refute Map.has_key?(note, "crdt_head")
      refute Map.has_key?(note, "tags")
    end

    test "never leaks another user's notes", %{conn: conn} do
      post(conn, "/api/notes", %{path: "Mine.md", content: "# Mine", mtime: 1_000.0})

      other = insert(:user)
      insert(:subscription, user: other, tier: "pro", status: "active")
      _other_vault = insert(:vault, user: other, is_default: true)
      {:ok, other_key, _} = Engram.Accounts.create_api_key(other, "other-key")
      grant_api_write!(other)

      other_conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{other_key}")

      # Must assert the write actually landed — otherwise a 401/403/422 here
      # (auth reordering, a new required header, a subscription-gate change)
      # silently creates zero rows, and `refute "Theirs.md" in paths` below
      # passes vacuously against an empty set instead of proving isolation.
      assert %{"note" => _} =
               json_response(
                 post(other_conn, "/api/notes", %{
                   path: "Theirs.md",
                   content: "# T",
                   mtime: 1_000.0
                 }),
                 200
               )

      body = conn |> get("/api/vault/tree") |> json_response(200)
      paths = Enum.map(body["notes"], & &1["path"])

      assert "Mine.md" in paths
      refute "Theirs.md" in paths
    end

    test "never leaks a note from another vault of the SAME user", %{conn: conn, user: user} do
      # user_id alone (no vault_id filter) would already pass every other
      # test here, since the isolation tests above use separate users with
      # separate vaults. This proves the `n.vault_id == ^vault.id` clause in
      # VaultTreeController.render_tree/5 actually does something.
      post(conn, "/api/notes", %{path: "InDefaultVault.md", content: "# d", mtime: 1_000.0})

      {:ok, other_vault, _} = Engram.Vaults.register_vault(user, "Other", Ecto.UUID.generate())

      other_vault_conn = put_req_header(conn, "x-vault-id", to_string(other_vault.id))

      assert %{"note" => _} =
               json_response(
                 post(other_vault_conn, "/api/notes", %{
                   path: "InOtherVault.md",
                   content: "# o",
                   mtime: 1_000.0
                 }),
                 200
               )

      body = conn |> get("/api/vault/tree") |> json_response(200)
      paths = Enum.map(body["notes"], & &1["path"])

      assert "InDefaultVault.md" in paths
      refute "InOtherVault.md" in paths
    end

    test "skips an undecryptable attachment instead of 500ing the whole tree", %{
      conn: conn,
      user: user
    } do
      post(conn, "/api/attachments", %{
        path: "good.png",
        content_base64: Base.encode64("X"),
        mtime: 1_000.0
      })

      %{"attachment" => %{"id" => bad_id}} =
        json_response(
          post(conn, "/api/attachments", %{
            path: "bad.png",
            content_base64: Base.encode64("Y"),
            mtime: 1_000.0
          }),
          200
        )

      # Corrupt the bad row's path ciphertext so AEAD verification fails —
      # same technique as Attachments' own "skips an undecryptable row"
      # test (test/engram/attachments_test.exs).
      Engram.Repo.with_tenant(user.id, fn ->
        from(a in Attachment, where: a.id == ^bad_id)
        |> Engram.Repo.update_all(set: [path_ciphertext: :crypto.strong_rand_bytes(48)])
      end)

      log =
        capture_log(fn ->
          body = conn |> get("/api/vault/tree") |> json_response(200)
          paths = Enum.map(body["attachments"], & &1["path"])

          assert "good.png" in paths
          refute "bad.png" in paths
          assert length(body["attachments"]) == 1
        end)

      assert log =~ "Skipping undecryptable attachment"
    end

    test "a non-:no_dek DEK failure 500s instead of raising an unhandled CaseClauseError", %{
      conn: conn,
      user: user
    } do
      # Same corruption technique used by
      # test/engram/mcp/handlers_test.exs's "unexpected crypto error"
      # case — a garbage encrypted_dek blob makes Crypto.get_dek/1 return
      # {:error, :unrecognised_blob}, the third case show/2 must now handle
      # explicitly instead of falling through to a CaseClauseError.
      corrupt = Ecto.Changeset.change(user, encrypted_dek: :crypto.strong_rand_bytes(32))
      {:ok, _corrupt_user} = Engram.Repo.update(corrupt, skip_tenant_check: true)

      log =
        capture_log(fn ->
          assert_error_sent(500, fn -> get(conn, "/api/vault/tree") end)
        end)

      assert log =~ "vault tree: DEK unavailable"
    end
  end
end
