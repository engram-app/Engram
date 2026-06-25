defmodule Engram.Notes.Utf8BackfillTest do
  use Engram.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Engram.Crypto
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Notes.Utf8Backfill
  alias Engram.Repo

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  # Persist a row whose content decrypts to invalid UTF-8 — a legacy row written
  # before the #727/#740 write-time scrub. We write a clean note, then overwrite
  # its content ciphertext in place with bytes that are invalid UTF-8 at rest.
  defp corrupt_note!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{
        "path" => path,
        "content" => "# Title\n\nclean placeholder",
        "mtime" => 1.0
      })

    bad = "# Title\n\nlead" <> <<0xE2>> <> "byte"
    {:ok, enc} = Crypto.encrypt_note_fields(%{content: bad, title: "Title"}, user, note.id)

    {:ok, {1, _}} =
      Repo.with_tenant(user.id, fn ->
        from(n in Note, where: n.id == ^note.id)
        |> Repo.update_all(
          set: [content_ciphertext: enc.content_ciphertext, content_nonce: enc.content_nonce]
        )
      end)

    note
  end

  defp raw_content(user, note_id) do
    {:ok, note} = Repo.with_tenant(user.id, fn -> Repo.get!(Note, note_id) end)
    {:ok, decrypted} = Crypto.decrypt_note_fields_unscrubbed(note, user)
    decrypted.content
  end

  test "counts corrupt-at-rest rows without mutating them", %{user: user, vault: vault} do
    note = corrupt_note!(user, vault, "Test/Corrupt.md")

    result = Utf8Backfill.scan()

    assert result.corrupt == 1
    assert result.fixed == 0
    assert result.scanned >= 1
    # Untouched: raw decrypt is still invalid UTF-8.
    refute String.valid?(raw_content(user, note.id))
  end

  test "fix: true rewrites corrupt rows so they are valid UTF-8 at rest",
       %{user: user, vault: vault} do
    note = corrupt_note!(user, vault, "Test/Corrupt.md")

    result = Utf8Backfill.scan(fix: true)

    assert result.corrupt == 1
    assert result.fixed == 1
    # The row now decrypts to valid UTF-8 even WITHOUT the read-boundary scrub.
    assert String.valid?(raw_content(user, note.id))
  end

  test "leaves valid rows untouched (no false positives)", %{user: user, vault: vault} do
    {:ok, _} =
      Notes.upsert_note(user, vault, %{
        "path" => "Test/Clean.md",
        "content" => "# Clean\n\nall good — 日本語",
        "mtime" => 1.0
      })

    result = Utf8Backfill.scan(fix: true)

    assert result.corrupt == 0
    assert result.fixed == 0
  end
end
