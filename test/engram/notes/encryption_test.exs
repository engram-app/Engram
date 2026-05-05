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
      vault = insert(:vault, user: user, encrypted: true)

      {:ok, _note} =
        Notes.upsert_note(user, vault, %{
          "path" => "journal/today.md",
          "content" => "dear diary, I feel seen",
          "mtime" => 1_000.0
        })

      # Public read path decrypts and returns plaintext
      {:ok, note} = Notes.get_note(user, vault, "journal/today.md")
      assert note.content == "dear diary, I feel seen"

      # Raw DB: plaintext content is replaced by empty string (default_content guard),
      # title is nil, ciphertext columns are populated, nonce is 12 bytes,
      # and the ciphertext bytes do NOT equal the plaintext string.
      {:ok, raw} =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.get_by!(Engram.Notes.Note, path: "journal/today.md", user_id: user.id)
        end)

      # content is cleared (coerced to "" by the changeset default_content guard)
      assert raw.content == ""
      # title is nil (no default coercion)
      assert raw.title == nil
      # ciphertext columns are populated
      assert is_binary(raw.content_ciphertext)
      assert byte_size(raw.content_ciphertext) > 0
      # nonce is exactly 12 bytes (AES-256-GCM standard)
      assert byte_size(raw.content_nonce) == 12
      # ciphertext does not equal the original plaintext bytes
      refute raw.content_ciphertext == "dear diary, I feel seen"
    end

    test "upsert returns plaintext struct (not encrypted)" do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user, encrypted: true)

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
      vault = insert(:vault, user: user, encrypted: true)

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
      vault = insert(:vault, user: user, encrypted: true)

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

    test "decrypt error logs without crashing" do
      import ExUnit.CaptureLog

      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault = insert(:vault, user: user, encrypted: true)

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "broken/note.md",
          "content" => "will be unreadable",
          "mtime" => 1_000.0,
          "version" => 1
        })

      # Corrupt the ciphertext in the DB so Envelope.decrypt returns an error
      {:ok, raw} =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.get_by!(Engram.Notes.Note, path: "broken/note.md", user_id: user.id)
        end)

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

      log =
        capture_log(fn ->
          result = Notes.get_note(user, vault, "broken/note.md")

          case result do
            {:ok, n} ->
              # Decrypt failed: returned struct should NOT contain the original plaintext
              refute n.content == "will be unreadable"

            {:error, _} ->
              # Also acceptable: error is surfaced instead of silently returning corrupt data
              :ok
          end
        end)

      # The error was logged with user_id and note_id for operator triage
      assert log =~ "decrypt_failed"
      assert log =~ "user_id=#{user.id}"
      assert log =~ "note_id=#{note.id}"

      # Critical: log must NOT contain the plaintext or any DEK material
      refute log =~ "will be unreadable"
    end

    test "unencrypted vault stores plaintext unchanged, ciphertext is nil" do
      user = insert(:user)
      vault = insert(:vault, user: user, encrypted: false)

      {:ok, _note} =
        Notes.upsert_note(user, vault, %{
          "path" => "recipes/chicken.md",
          "content" => "400F for 25min",
          "mtime" => 1_000.0
        })

      {:ok, raw} =
        Engram.Repo.with_tenant(user.id, fn ->
          Engram.Repo.get_by!(Engram.Notes.Note, path: "recipes/chicken.md", user_id: user.id)
        end)

      assert raw.content == "400F for 25min"
      assert raw.content_ciphertext == nil
    end
  end
end
