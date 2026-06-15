defmodule Engram.KeywordIndex.PostgresTest do
  @moduledoc """
  Unit tests for the native-Postgres keyword-search adapter (tsvector +
  ts_rank_cd). Proves the leg #595 wants: exact-term recall that dense vector
  search misses (identifiers, code, exact strings), plus per-tenant isolation.
  """
  use Engram.DataCase, async: true

  alias Engram.Fixtures
  alias Engram.KeywordIndex.Postgres

  setup do
    {:ok, user} = Fixtures.user_with_dek_fixture()
    vault = Fixtures.insert_vault!(user, "Test Vault")
    %{user: user, vault: vault}
  end

  # The decrypted-note shape EmbedNote hands to the keyword index: the persisted
  # row plus the plaintext `content`/`title` virtual fields populated.
  defp decrypted(user, vault, content, title) do
    note = Fixtures.insert_note!(user, vault, %{content: content, title: title})
    %{note | content: content, title: title}
  end

  describe "upsert/1 then search/3" do
    test "recalls a note by an exact identifier in its body", %{user: user, vault: vault} do
      note = decrypted(user, vault, "The deploy secret is PADDLE_API_KEY=sk_live_abc123", "Secrets")

      assert :ok = Postgres.upsert(note)

      assert {:ok, results} =
               Postgres.search("PADDLE_API_KEY", %{user_id: user.id, vault_id: vault.id}, limit: 5)

      assert note.id in Enum.map(results, fn {note_id, _rank} -> note_id end)
    end

    test "does not recall notes for an unrelated query", %{user: user, vault: vault} do
      note = decrypted(user, vault, "Notes about gardening and tomatoes", "Garden")
      assert :ok = Postgres.upsert(note)

      assert {:ok, results} =
               Postgres.search("PADDLE_API_KEY", %{user_id: user.id, vault_id: vault.id}, limit: 5)

      refute note.id in Enum.map(results, fn {note_id, _rank} -> note_id end)
    end

    test "re-upsert replaces the prior vector (no duplicate, reflects new text)",
         %{user: user, vault: vault} do
      note = decrypted(user, vault, "first body mentions alpha", "T")
      assert :ok = Postgres.upsert(note)
      # Same note id, new content — must overwrite, not insert a second row.
      assert :ok = Postgres.upsert(%{note | content: "second body mentions bravo"})

      assert {:ok, gone} = Postgres.search("alpha", %{user_id: user.id, vault_id: vault.id}, limit: 5)
      refute note.id in Enum.map(gone, fn {id, _} -> id end)

      assert {:ok, hit} = Postgres.search("bravo", %{user_id: user.id, vault_id: vault.id}, limit: 5)
      assert note.id in Enum.map(hit, fn {id, _} -> id end)
    end
  end

  describe "tenant isolation" do
    test "never returns another user's note for the same keyword", %{user: user, vault: vault} do
      {:ok, other} = Fixtures.user_with_dek_fixture()
      other_vault = Fixtures.insert_vault!(other, "Other Vault")

      mine = decrypted(user, vault, "shared keyword WIDGET here", "Mine")
      theirs = decrypted(other, other_vault, "shared keyword WIDGET here", "Theirs")
      assert :ok = Postgres.upsert(mine)
      assert :ok = Postgres.upsert(theirs)

      assert {:ok, results} =
               Postgres.search("WIDGET", %{user_id: user.id, vault_id: vault.id}, limit: 5)

      ids = Enum.map(results, fn {id, _} -> id end)
      assert mine.id in ids
      refute theirs.id in ids
    end
  end
end
