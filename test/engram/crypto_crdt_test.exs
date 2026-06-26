defmodule Engram.CryptoCrdtTest do
  use Engram.DataCase, async: true

  alias Engram.Crypto
  alias Engram.Fixtures
  alias Engram.Notes.Note

  setup do
    {:ok, user} = Fixtures.user_with_dek_fixture()
    %{user: user}
  end

  test "encrypt/decrypt crdt_state round-trips under the DEK + AAD", %{user: user} do
    note_id = Ecto.UUID.generate()
    state = <<0, 1, 2, 3, 99, 200, 255>>

    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(state, user, note_id)
    assert is_binary(ct) and is_binary(nonce)
    assert byte_size(nonce) == 12
    refute ct == state

    note = %Note{
      id: note_id,
      dek_version: Crypto.row_version_aad_bound(),
      crdt_state_ciphertext: ct,
      crdt_state_nonce: nonce
    }

    assert {:ok, ^state} = Crypto.decrypt_crdt_state(note, user)
  end

  test "decrypt_crdt_state returns {:ok, nil} when no ciphertext present", %{user: user} do
    note = %Note{id: Ecto.UUID.generate(), crdt_state_ciphertext: nil, crdt_state_nonce: nil}
    assert {:ok, nil} = Crypto.decrypt_crdt_state(note, user)
  end

  test "AAD bind: ciphertext from one note id cannot decrypt under another", %{user: user} do
    id_a = Ecto.UUID.generate()
    id_b = Ecto.UUID.generate()
    {:ok, {ct, nonce}} = Crypto.encrypt_crdt_state(<<7, 7, 7>>, user, id_a)

    note_b = %Note{
      id: id_b,
      dek_version: Crypto.row_version_aad_bound(),
      crdt_state_ciphertext: ct,
      crdt_state_nonce: nonce
    }

    assert {:error, :decrypt_failed} = Crypto.decrypt_crdt_state(note_b, user)
  end
end
