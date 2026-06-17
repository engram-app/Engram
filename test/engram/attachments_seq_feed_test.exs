defmodule Engram.AttachmentsSeqFeedTest do
  use Engram.DataCase, async: true

  alias Engram.{Attachments, Repo, Vaults}

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

  defp put(user, vault, path) do
    Attachments.upsert_attachment(user, vault, %{
      "path" => path,
      "content_base64" => b64(path),
      "mime_type" => "image/png"
    })
  end

  test "version starts at 1 and bumps on update", %{user: user, vault: vault} do
    {:ok, a} = put(user, vault, "a.png")
    assert att_row(user, a.id).version == 1

    {:ok, _} = put(user, vault, "a.png")
    assert att_row(user, a.id).version == 2
  end
end
