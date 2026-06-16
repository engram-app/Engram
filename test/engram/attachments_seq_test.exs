defmodule Engram.AttachmentsSeqTest do
  use Engram.DataCase, async: true

  alias Engram.{Attachments, Vaults, Repo}

  setup do
    user = insert_user()
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  defp b64(bin), do: Base.encode64(bin)

  defp att_row(user, id) do
    {:ok, row} = Repo.with_tenant(user.id, fn -> Repo.get(Attachments.Attachment, id) end)
    row
  end

  test "upsert_attachment stamps a monotonic seq", %{user: user, vault: vault} do
    {:ok, a1} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => "img/a.png",
        "content_base64" => b64("PNGDATA"),
        "mime_type" => "image/png"
      })

    {:ok, a2} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => "img/b.png",
        "content_base64" => b64("PNGDATB"),
        "mime_type" => "image/png"
      })

    r1 = att_row(user, a1.id)
    r2 = att_row(user, a2.id)
    assert is_integer(r1.seq) and is_integer(r2.seq)
    assert r2.seq > r1.seq
  end

  test "delete_attachment stamps a new seq", %{user: user, vault: vault} do
    {:ok, a} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => "img/a.png",
        "content_base64" => b64("PNGDATA"),
        "mime_type" => "image/png"
      })

    before = att_row(user, a.id).seq
    :ok = Attachments.delete_attachment(user, vault, "img/a.png")
    after_ = att_row(user, a.id)
    assert after_.deleted_at != nil
    assert after_.seq > before
  end
end
