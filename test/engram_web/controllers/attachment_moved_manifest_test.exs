defmodule EngramWeb.AttachmentMovedManifestTest do
  # S6 step 6 (Engram#2523): `GET /api/sync/manifest` lists an attachment left
  # under a folder moved without a cascade at its shown path, with the move's
  # seq, so a plugin diffing the manifest neither re-uploads it nor trashes
  # it at the old path.
  use EngramWeb.ConnCase, async: false

  alias Engram.{Attachments, Notes, Repo}

  setup %{conn: conn} do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    lift_api_rps_cap!(user)

    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => "A/n.md", "content" => "n"}, actor: "api")

    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => "A/x.png",
        "content_base64" => Base.encode64("bytes")
      })

    {:ok, {:ok, 1}} =
      Repo.with_tenant(user.id, fn -> Notes.rename_folder_uncascaded(user, vault, "A", "B") end)

    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}"), att: att}
  end

  test "the moved attachment is listed at its shown path and the move's seq",
       %{conn: conn, att: att} do
    body = json_response(get(conn, "/api/sync/manifest"), 200)

    assert [%{"id" => id, "path" => "B/x.png", "seq" => seq}] = body["attachments"]
    assert id == att.id
    assert seq > att.seq
    assert [%{"path" => "B/n.md"}] = body["notes"]
  end
end
