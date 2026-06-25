defmodule Engram.MCP.HandlersGetNoteUtf8Test do
  # Regression for #726: `get_note` silently truncated a note body, returning
  # only the "header + intro" and dropping the rest. Root cause was an invalid
  # UTF-8 byte at rest (same source as the #727 search 500 / #745 tag byte-slice):
  # the bad byte broke the JSON egress, so only the bytes *before* it reached the
  # client. The #740 read-boundary scrub (Crypto.maybe_decrypt_note_fields, which
  # get_note flows through) now replaces the bad byte with U+FFFD and preserves
  # the full body. This test drives the real handler path to lock that the tail
  # after the bad byte is never dropped again.
  use Engram.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Engram.Crypto
  alias Engram.MCP.Handlers
  alias Engram.Notes
  alias Engram.Notes.Note
  alias Engram.Repo

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  # Persist a row whose content decrypts to invalid UTF-8 — a legacy row written
  # before the #727/#740 write-time scrub. Write a clean note, then overwrite its
  # content ciphertext in place with bytes that are invalid UTF-8 at rest.
  defp corrupt_note!(user, vault, path, bad) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{
        "path" => path,
        "content" => "# Title\n\nclean placeholder",
        "mtime" => 1.0
      })

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

  test "get_note returns the full body when content has an invalid UTF-8 byte at rest",
       %{user: user, vault: vault} do
    head = "# Title\n\nIntro before the bad byte."
    tail = "Tail after the bad byte — this is what #726 silently dropped."
    # A lone 0xE2 — the lead byte of a multibyte char (e.g. en-dash) with its
    # continuation bytes missing. Invalid UTF-8, sitting between head and tail.
    corrupt_note!(user, vault, "Test/Corrupt.md", head <> <<0xE2>> <> tail)

    assert {:ok, out} =
             Handlers.handle("get_note", user, vault, %{"source_path" => "Test/Corrupt.md"})

    # The output is clean UTF-8 — no raw bad byte leaks to the JSON boundary.
    assert String.valid?(out)
    # Intro survives (it always did — this is the "header + intro" the bug returned)…
    assert out =~ "Intro before the bad byte."
    # …and so does the tail. Pre-#740 this was truncated away.
    assert out =~ "Tail after the bad byte"
    # The bad byte was replaced, not dropped — body length is preserved, not cut.
    assert out =~ "�"
  end
end
