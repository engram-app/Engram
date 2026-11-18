defmodule EngramWeb.AttachmentHealConflictTest do
  # S6 step 6 (Engram#2523): a write at the shown path of an attachment left
  # under a folder moved without a cascade first repoints its stale stored
  # path (`Engram.Attachments.settle/3`). When that cannot land (the shown
  # slot is held by another file shown there) the write is refused as
  # `{:error, :conflict}`, which every HTTP surface must answer as the
  # retryable 409 `conflict`, never a 500 nor a 200 that overwrote nothing.
  use EngramWeb.ConnCase, async: false

  alias Engram.{Attachments, Notes, Repo}

  setup %{conn: conn} do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    insert(:subscription, user: user, tier: "pro", status: "active")
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    lift_api_rps_cap!(user)

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "A/n.md", "content" => "n"}, actor: "api")

    _moved = put_att(user, vault, "A/x.png", "old bytes")
    other = put_att(user, vault, "C/z.png", "other file")

    {:ok, {:ok, 1}} =
      Repo.with_tenant(user.id, fn -> Notes.rename_folder_uncascaded(user, vault, "A", "B") end)

    # `other` holds B/x.png's slot by its stored key, unkeyed, so it is shown
    # there too: the moved row's heal cannot land (location_test's B2 case).
    {:ok, fk} = Engram.Crypto.dek_filter_key(user)

    Repo.query!(
      "UPDATE attachments SET path_hmac = $2, folder_ref_stamp = NULL WHERE id = $1",
      [Ecto.UUID.dump!(other.id), Engram.Crypto.hmac_field(fk, "B/x.png")]
    )

    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}")}
  end

  defp put_att(user, vault, path, bytes) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64(bytes)
      })

    att
  end

  defp idem(conn), do: put_req_header(conn, "x-idempotency-key", Ecto.UUID.generate())

  test "upload", %{conn: conn} do
    conn =
      post(conn, "/api/attachments", %{
        path: "B/x.png",
        content_base64: Base.encode64("would overwrite"),
        mtime: 1.0
      })

    assert json_response(conn, 409) == %{"error" => "conflict"}
  end

  test "chunked upload start", %{conn: conn} do
    conn = post(conn, "/api/attachment-uploads", %{path: "B/x.png", size_bytes: 5, mtime: 1.0})
    assert json_response(conn, 409) == %{"error" => "conflict"}
  end

  test "single delete", %{conn: conn} do
    assert json_response(delete(conn, "/api/attachments/B/x.png"), 409) == %{
             "error" => "conflict"
           }
  end

  test "batch delete", %{conn: conn} do
    conn = conn |> idem() |> post("/api/attachments/batch-delete", %{paths: ["B/x.png"]})
    assert json_response(conn, 409) == %{"error" => "conflict"}
  end

  test "rename", %{conn: conn} do
    conn = post(conn, "/api/attachments/rename", %{old_path: "B/x.png", new_path: "B/y.png"})
    assert %{"error" => "conflict"} = json_response(conn, 409)
  end

  test "batch move", %{conn: conn} do
    conn =
      conn
      |> idem()
      |> post("/api/attachments/batch-move", %{paths: ["B/x.png"], target_folder: "D"})

    assert %{"error" => "conflict"} = json_response(conn, 409)
  end

  test "recursive folder delete", %{conn: conn} do
    conn = delete(conn, "/api/folders/B?recursive=true")
    assert json_response(conn, 409) == %{"error" => "conflict"}
  end
end
