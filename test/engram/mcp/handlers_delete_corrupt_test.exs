defmodule Engram.MCP.HandlersDeleteCorruptTest do
  @moduledoc """
  #1660 gave `delete_note` an existence probe so its payload could say whether
  anything was actually there. The probe used `Notes.get_note/3`, which
  decrypts via `decrypt_or_raise!` — but `Notes.delete_note/4` never decrypts,
  it works on the raw row.

  So the probe made deleting an UNDECRYPTABLE note fail, on exactly the path
  you need when cleaning one up.
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

  test "a note whose content will not decrypt can still be deleted", %{
    user: user,
    vault: vault
  } do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "a.md", "content" => "hi"})

    # Corrupt the ciphertext in place — the row stays live and findable by
    # path, but any decrypt of it raises.
    {1, _} =
      Engram.Repo.update_all(
        Ecto.Query.from(n in Notes.Note, where: n.id == ^note.id),
        [set: [content_ciphertext: :crypto.strong_rand_bytes(48)]],
        skip_tenant_check: true
      )

    assert {:ok, text, structured} =
             Handlers.handle("delete_note", user, vault, %{"path" => "a.md"})

    assert structured["deleted"] == true
    assert text =~ "Note deleted"
  end

  test "still reports false for a path that was never there", %{user: user, vault: vault} do
    assert {:ok, _text, %{"deleted" => false}} =
             Handlers.handle("delete_note", user, vault, %{"path" => "never.md"})
  end
end
