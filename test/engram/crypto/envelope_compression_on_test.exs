defmodule Engram.Crypto.EnvelopeCompressionOnTest do
  # async: false: one test flips the global :envelope_compression flag.
  # Relies on the DEFAULT config (policy on) -- no setup that enables it.
  use Engram.DataCase, async: false

  import Mox

  alias Engram.{Attachments, Crypto, Notes}
  alias Engram.Notes.Note

  setup :verify_on_exit!

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)

    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp write_note(user, vault, path, content) do
    {:ok, _} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => 1.0},
        actor: "api"
      )

    Engram.Fixtures.raw_note_by_path!(user, path)
  end

  defp upload(user, vault, path, bytes) do
    test_pid = self()

    expect(Engram.MockStorage, :put, fn _key, stored, _opts ->
      send(test_pid, {:stored, stored})
      :ok
    end)

    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64(bytes),
        "mtime" => 0.0
      })

    assert_receive {:stored, stored}
    {att, stored}
  end

  test "default config is policy on" do
    assert Application.get_env(:engram, :envelope_compression) == true
  end

  test "a new note's content is format 1 (13-byte nonce), its title format 0", %{
    user: user,
    vault: vault
  } do
    raw = write_note(user, vault, "a.md", String.duplicate("compressible line\n", 200))
    assert byte_size(raw.content_nonce) == 13
    assert byte_size(raw.title_nonce) == 12
    # zstd actually shrank it
    assert byte_size(raw.content_ciphertext) < 18 * 200
  end

  test "a policy-on row still decrypts with the policy off (rollback read)", %{
    user: user,
    vault: vault
  } do
    content = String.duplicate("compressible line\n", 200)
    raw = write_note(user, vault, "rb.md", content)
    assert byte_size(raw.content_nonce) == 13

    prev = Application.get_env(:engram, :envelope_compression)
    Application.put_env(:engram, :envelope_compression, false)
    on_exit(fn -> Application.put_env(:engram, :envelope_compression, prev) end)

    assert {:ok, %Note{content: ^content}} = Notes.get_note(user, vault, "rb.md")
  end

  test "200 KB of random bytes is stored format 1 raw (plain + 1 + 16)", %{
    user: user,
    vault: vault
  } do
    stub_with(Engram.MockStorage, Engram.Storage.InMemory)
    random = :crypto.strong_rand_bytes(200_000)
    {att, stored} = upload(user, vault, "r.png", random)

    assert byte_size(att.content_nonce) == 13
    assert byte_size(stored) == 200_000 + 1 + 16
  end

  test "200 KB of markdown is stored format 1 zstd (smaller)", %{user: user, vault: vault} do
    stub_with(Engram.MockStorage, Engram.Storage.InMemory)
    md = String.duplicate("# heading\n\nsome markdown prose, repeated.\n", 5_000)
    {att, stored} = upload(user, vault, "m.pdf", md)

    assert byte_size(att.content_nonce) == 13
    assert byte_size(stored) < byte_size(md) / 4
  end
end
