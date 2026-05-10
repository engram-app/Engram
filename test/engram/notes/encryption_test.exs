defmodule Engram.Notes.EncryptionTest do
  use Engram.DataCase, async: false

  alias Engram.Crypto.DekCache
  alias Engram.Notes

  # DekCache is a global GenServer; must be synchronous and flushed between tests.
  setup do
    DekCache.invalidate_all()
    :ok
  end

  describe "encrypted vault round-trip" do
    test "upsert then read returns plaintext, DB columns hold ciphertext" do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user)

      {:ok, _note} =
        Notes.upsert_note(user, vault, %{
          "path" => "journal/today.md",
          "content" => "dear diary, I feel seen",
          "mtime" => 1_000.0
        })

      # Public read path decrypts and returns plaintext
      {:ok, note} = Notes.get_note(user, vault, "journal/today.md")
      assert note.content == "dear diary, I feel seen"

      # Raw DB: virtual content/title fields stay nil on the unhydrated
      # struct (Phase B.4 — only ciphertext columns are persisted). The
      # ciphertext columns are populated and don't equal the plaintext.
      raw = Engram.Fixtures.raw_note_by_path!(user, "journal/today.md")

      assert raw.content == nil
      assert raw.title == nil
      assert is_binary(raw.content_ciphertext)
      assert byte_size(raw.content_ciphertext) > 0
      assert byte_size(raw.content_nonce) == 12
      refute raw.content_ciphertext == "dear diary, I feel seen"
    end

    test "upsert returns plaintext struct (not encrypted)" do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user)

      {:ok, note} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "return/test.md",
          "content" => "plain text returned",
          "mtime" => 1_000.0,
          "version" => 1
        })

      # The returned struct must contain plaintext, not ciphertext
      assert note.content == "plain text returned"
      refute note.title == nil
    end

    test "rename_note returns plaintext struct for encrypted vault" do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user)

      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{
          "path" => "rename/before.md",
          "content" => "# Before\n\nsome content here",
          "mtime" => 1_000.0
        })

      {:ok, renamed} =
        Engram.Notes.rename_note(user, vault, "rename/before.md", "rename/after.md")

      # Returned struct must be plaintext
      assert renamed.path == "rename/after.md"
      assert renamed.content == "# Before\n\nsome content here"
    end

    test "rename on encrypted vault derives title from decrypted heading" do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user)

      original_content = "# The Real Title\n\nbody text here"

      {:ok, _} =
        Notes.upsert_note(user, vault, %{
          "path" => "before/note.md",
          "content" => original_content,
          "mtime" => 1_000.0,
          "version" => 1
        })

      {:ok, renamed} = Notes.rename_note(user, vault, "before/note.md", "after/note.md")

      # Title must be derived from the decrypted heading, not the new path filename.
      # If decrypt failed and fell back to the encrypted struct, extract_title would
      # see ciphertext bytes and produce a garbage or path-derived title — this
      # assertion catches that regression.
      assert renamed.title == "The Real Title"
    end

    test "decrypt error raises with operator-friendly metadata, never silently nullifies fields" do
      import ExUnit.CaptureLog

      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user)

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "broken/note.md",
          "content" => "will be unreadable",
          "mtime" => 1_000.0,
          "version" => 1
        })

      # Corrupt the ciphertext in the DB so Envelope.decrypt returns an error
      raw = Engram.Fixtures.raw_note_by_path!(user, "broken/note.md")

      <<first, rest::binary>> = raw.content_ciphertext
      tampered_ct = <<Bitwise.bxor(first, 1), rest::binary>>

      {:ok, _} =
        Engram.Repo.with_tenant(user.id, fn ->
          raw
          |> Ecto.Changeset.change(content_ciphertext: tampered_ct)
          |> Engram.Repo.update()
        end)

      # Clear DEK cache to force a fresh unwrap (removes a confounding variable)
      Engram.Crypto.DekCache.invalidate(user.id)

      # Phase B.3 contract: decrypt failure on a persisted row is data
      # corruption — must raise so the API returns 5xx + Sentry hit, never
      # serialize `{"path": null, "content": null}` over a 200 OK.
      log =
        capture_log(fn ->
          assert_raise RuntimeError, ~r/Phase B note decryption failed/, fn ->
            Notes.get_note(user, vault, "broken/note.md")
          end
        end)

      # Operator triage metadata in the log line
      assert log =~ "decrypt_failed"
      assert log =~ "user_id=#{user.id}"
      assert log =~ "note_id=#{note.id}"

      # Log must NOT contain the plaintext or any DEK material
      refute log =~ "will be unreadable"
    end
  end
end
