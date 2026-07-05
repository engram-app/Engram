defmodule Engram.CryptoOkfFieldsTest do
  use Engram.DataCase, async: true

  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.Notes.Note

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    %{user: user}
  end

  test "maybe_decrypt_note_fields populates type/description/resource virtuals", %{user: user} do
    {:ok, dek} = Crypto.get_dek(user)
    note_id = Ecto.UUID.generate()

    {type_ct, type_n} =
      Envelope.encrypt("Playbook", dek, Crypto.aad_for_row(:notes, :type, note_id))

    {desc_ct, desc_n} =
      Envelope.encrypt("A short summary.", dek, Crypto.aad_for_row(:notes, :description, note_id))

    {res_ct, res_n} =
      Envelope.encrypt("https://x.test/r", dek, Crypto.aad_for_row(:notes, :resource, note_id))

    note = %Note{
      id: note_id,
      dek_version: Crypto.row_version_aad_bound(),
      type_ciphertext: type_ct,
      type_nonce: type_n,
      description_ciphertext: desc_ct,
      description_nonce: desc_n,
      resource_ciphertext: res_ct,
      resource_nonce: res_n
    }

    assert {:ok, decrypted} = Crypto.maybe_decrypt_note_fields(note, user)
    assert decrypted.type == "Playbook"
    assert decrypted.description == "A short summary."
    assert decrypted.resource == "https://x.test/r"
  end

  test "notes without OKF ciphertext decrypt to nil virtuals", %{user: user} do
    note = %Note{id: Ecto.UUID.generate()}
    assert {:ok, decrypted} = Crypto.maybe_decrypt_note_fields(note, user)
    assert decrypted.type == nil
    assert decrypted.description == nil
    assert decrypted.resource == nil
  end
end
