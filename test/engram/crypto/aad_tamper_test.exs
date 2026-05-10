defmodule Engram.Crypto.AadTamperTest do
  @moduledoc """
  T3.6 / H1 — end-to-end tamper regression. Cross-row, cross-column, and
  cross-user ciphertext swap must fail decrypt rather than silently
  succeed under the wrong identity.
  """

  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Crypto.{DekCache, Envelope}
  alias Engram.Notes
  alias Engram.Repo

  setup do
    DekCache.invalidate_all()
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Tamper Vault"})
    {:ok, user: user, vault: vault}
  end

  test "cross-row swap fails: copy A's content_ciphertext into B's slot",
       %{user: user, vault: vault} do
    {:ok, note_a} = Notes.upsert_note(user, vault, %{path: "a.md", content: "secret-A"})
    {:ok, note_b} = Notes.upsert_note(user, vault, %{path: "b.md", content: "secret-B"})

    # Pull both rows fresh — `upsert_note` returns the decrypted struct,
    # but we want the raw ciphertext columns from disk.
    raw_a = Repo.get!(Engram.Notes.Note, note_a.id, skip_tenant_check: true)
    raw_b = Repo.get!(Engram.Notes.Note, note_b.id, skip_tenant_check: true)

    # Splice A's content ciphertext + nonce into B's record (in-memory) and
    # ask the read path to decrypt. AAD reconstructed from B's row id MUST
    # fail the AEAD tag check.
    forged =
      %{raw_b | content_ciphertext: raw_a.content_ciphertext, content_nonce: raw_a.content_nonce}

    assert {:error, :decrypt_failed} = Crypto.maybe_decrypt_note_fields(forged, user)
  end

  test "within-row column swap fails: content_ciphertext into title slot",
       %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{path: "swap.md", content: "secret-content"})

    raw = Repo.get!(Engram.Notes.Note, note.id, skip_tenant_check: true)

    forged =
      %{raw | title_ciphertext: raw.content_ciphertext, title_nonce: raw.content_nonce}

    # The :content slot still decrypts cleanly under "notes:content:<id>";
    # :title fails because AAD = "notes:title:<id>" doesn't match the
    # ciphertext's bound context.
    assert {:error, :decrypt_failed} = Crypto.maybe_decrypt_note_fields(forged, user)
  end

  test "cross-user swap fails because per-user DEK derivation diverges",
       %{user: user_a, vault: vault_a} do
    user_b = insert(:user)
    {:ok, user_b} = Crypto.ensure_user_dek(user_b)
    {:ok, vault_b} = Engram.Vaults.create_vault(user_b, %{name: "B Vault"})

    {:ok, note_a} = Notes.upsert_note(user_a, vault_a, %{path: "a.md", content: "user-a-secret"})
    {:ok, note_b} = Notes.upsert_note(user_b, vault_b, %{path: "b.md", content: "user-b-secret"})

    raw_a = Repo.get!(Engram.Notes.Note, note_a.id, skip_tenant_check: true)
    raw_b = Repo.get!(Engram.Notes.Note, note_b.id, skip_tenant_check: true)

    # Place B's ciphertext on A's row in memory. Per-user DEK already
    # blocks this, but adding row-id AAD makes the decryption attempt fail
    # at two independent gates.
    forged =
      %{raw_a | content_ciphertext: raw_b.content_ciphertext, content_nonce: raw_b.content_nonce}

    assert {:error, :decrypt_failed} = Crypto.maybe_decrypt_note_fields(forged, user_a)
  end

  test "wrapped-DEK is bound to the user it was generated for", %{user: user} do
    user_b = insert(:user)
    {:ok, user_b} = Crypto.ensure_user_dek(user_b)

    # Reload both wrapped blobs from DB.
    user_a_db = Repo.reload!(user, skip_tenant_check: true)
    user_b_db = Repo.reload!(user_b, skip_tenant_check: true)

    # Try to unwrap A's blob under B's user_id ctx. AAD = "dek:v1:<B>"
    # must not satisfy the AEAD tag for a wrap that was bound to "dek:v1:<A>".
    provider = Engram.Crypto.KeyProvider.Local

    assert {:error, _} =
             provider.unwrap_dek(user_a_db.encrypted_dek, %{user_id: user_b_db.id})

    # Unwrap A's blob under A's id succeeds (sanity).
    assert {:ok, _dek_a} =
             provider.unwrap_dek(user_a_db.encrypted_dek, %{user_id: user_a_db.id})
  end

  test "Envelope.decrypt fails without AAD on AAD-bound ciphertext", %{user: user, vault: vault} do
    {:ok, note} = Notes.upsert_note(user, vault, %{path: "no-aad.md", content: "needs-aad"})
    raw = Repo.get!(Engram.Notes.Note, note.id, skip_tenant_check: true)
    {:ok, dek} = Crypto.get_dek(user)

    # Decrypt without supplying any AAD — empty AAD does not match
    # "notes:content:<id>".
    assert :error = Envelope.decrypt(raw.content_ciphertext, raw.content_nonce, dek)

    # Sanity: with the right AAD, decrypt succeeds.
    aad = Crypto.aad_for_row(:notes, :content, note.id)

    assert {:ok, "needs-aad"} =
             Envelope.decrypt(raw.content_ciphertext, raw.content_nonce, dek, aad)
  end

  describe "post-rotation AAD bind" do
    # Bypass stubs the Qdrant scroll so rotate_user/1 can complete without a
    # real Qdrant instance. The sweep returns zero points, which is correct for
    # these tests (no embeddings seeded).
    setup do
      bypass = Bypass.open()
      Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
      on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/scroll", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"result" => %{"points" => [], "next_page_offset" => nil}})
        )
      end)

      :ok
    end

    test "swapping ciphertext between rotated rows still fails decrypt",
         %{user: user, vault: vault} do
      {:ok, note_a} = Notes.upsert_note(user, vault, %{path: "rot-a.md", content: "rotated-A"})
      {:ok, note_b} = Notes.upsert_note(user, vault, %{path: "rot-b.md", content: "rotated-B"})

      # Rotate the user's DEK — all rows are re-encrypted under the new DEK
      # but their AAD strings ("notes:content:<id>") remain bound to row id.
      assert :ok = Engram.Crypto.UserDekRotation.rotate_user(user.id)

      # Reload user so we have the updated encrypted_dek / dek_version.
      rotated_user = Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)

      # Pull fresh raw rows — ciphertext is now under the new DEK.
      raw_a = Repo.get!(Engram.Notes.Note, note_a.id, skip_tenant_check: true)
      raw_b = Repo.get!(Engram.Notes.Note, note_b.id, skip_tenant_check: true)

      # Splice A's rotated ciphertext + nonce into B's in-memory struct.
      # AAD reconstructed from B's row id ("notes:content:<B.id>") must NOT
      # satisfy the tag that was sealed under A's AAD ("notes:content:<A.id>").
      tampered = %{
        raw_b
        | content_ciphertext: raw_a.content_ciphertext,
          content_nonce: raw_a.content_nonce
      }

      assert {:error, :decrypt_failed} = Crypto.maybe_decrypt_note_fields(tampered, rotated_user)
    end
  end
end
