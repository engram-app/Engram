defmodule Engram.NotesOkfWriteTest do
  use Engram.DataCase, async: true
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.Note

  @content """
  ---
  type: Playbook
  description: Freshness alert triage.
  resource: https://x.test/dash
  timestamp: 2026-05-28T14:30:00Z
  created: 2026-05-01
  ---
  body
  """

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault} = Vaults.create_vault(user, %{"name" => "okf-test"})
    %{user: user, vault: vault}
  end

  test "upsert persists OKF columns and virtuals round-trip", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "a/x.md", "content" => @content})

    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    assert raw.fm_timestamp == ~U[2026-05-28 14:30:00Z]
    assert raw.fm_created == ~U[2026-05-01 00:00:00Z]
    refute is_nil(raw.type_ciphertext)
    refute is_nil(raw.type_hmac)
    refute is_nil(raw.description_ciphertext)
    refute is_nil(raw.resource_ciphertext)

    {:ok, decrypted} = Crypto.maybe_decrypt_note_fields(raw, user)
    assert decrypted.type == "Playbook"
    assert decrypted.description == "Freshness alert triage."
    assert decrypted.resource == "https://x.test/dash"
  end

  test "type_hmac uses the normalized value", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "b/y.md", "content" => @content})
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)

    {:ok, filter_key} = Crypto.dek_filter_key(user)
    assert raw.type_hmac == Crypto.hmac_field(filter_key, "playbook")
  end

  test "removing frontmatter on edit nulls the OKF columns", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => "c/z.md", "content" => @content})
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "c/z.md", "content" => "plain body\n"})

    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note.id) end)
    assert is_nil(raw.fm_timestamp)
    assert is_nil(raw.type_ciphertext)
    assert is_nil(raw.type_hmac)
  end

  test "batch upsert persists OKF columns", %{user: user, vault: vault} do
    {:ok, _} =
      Notes.batch_upsert_notes(user, vault, [%{"path" => "d/b.md", "content" => @content}])

    {:ok, raw} =
      Repo.with_tenant(user.id, fn ->
        Repo.one(from n in Note, where: n.vault_id == ^vault.id)
      end)

    assert raw.fm_timestamp == ~U[2026-05-28 14:30:00Z]
    refute is_nil(raw.type_hmac)
  end
end
