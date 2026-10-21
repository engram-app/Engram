defmodule Engram.Notes.NoteSplitTest do
  # Wave 3 dual-write: the notes_derive_core_keys / notes_sync_body triggers
  # keep the narrow core columns and note_bodies in step with every write,
  # and the NoteSplit data migration fills rows written before them.
  use Engram.DataCase, async: true

  alias Engram.DataMigrations.NoteSplit
  alias Engram.Notes
  alias Engram.Repo

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Split", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp write!(user, vault, path, content) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => content}, actor: "api")

    note
  end

  defp row(id) do
    %{rows: [row], columns: cols} =
      Repo.query!(
        """
        SELECT n.*, b.note_id IS NOT NULL AS has_body, b.content_ct AS b_content,
               b.crdt_ct AS b_crdt, b.crdt_head AS b_head, b.key_version AS b_key,
               b.xmin::text AS b_xmin
        FROM notes n LEFT JOIN note_bodies b ON b.note_id = n.id WHERE n.id = $1
        """,
        [Ecto.UUID.dump!(id)]
      )

    cols |> Enum.zip(row) |> Map.new()
  end

  defp id16(<<head::binary-16, _::binary>>), do: Ecto.UUID.load!(head)
  defp merged(<<_::binary-13>> = nonce, ct), do: nonce <> ct
  defp merged(nonce, ct), do: <<0>> <> nonce <> ct

  test "a note write fills the core keys and its body", %{user: u, vault: v} do
    note = write!(u, v, "Dir/Some Note.md", "---\ntype: idea\ntags: [a, b]\n---\n# T\n\nbody")
    r = row(note.id)

    assert Ecto.UUID.load!(r["path_id"]) == id16(r["path_hmac"])
    assert Ecto.UUID.load!(r["folder_id"]) == id16(r["folder_hmac"])
    assert Ecto.UUID.load!(r["basename_id"]) == id16(r["basename_hmac"])
    assert Ecto.UUID.load!(r["path_ci_id"]) == id16(r["path_ci_hmac"])
    assert Ecto.UUID.load!(r["type_id"]) == id16(r["type_hmac"])
    assert Enum.map(r["tag_ids"], &Ecto.UUID.load!/1) == Enum.map(r["tags_hmac"], &id16/1)
    assert r["is_folder"] == false
    assert r["key_version"] == r["dek_version"]
    assert r["path_len"] == r["path_length"]
    assert r["parse_code"] == 0
    assert r["content_digest"] == Base.decode16!(r["content_hash"], case: :lower)

    assert r["has_body"]
    assert r["b_content"] == merged(r["content_nonce"], r["content_ciphertext"])
    assert r["b_crdt"] == merged(r["crdt_state_nonce"], r["crdt_state_ciphertext"])
    assert r["b_key"] == r["dek_version"]
  end

  test "the body the trigger merged in SQL opens with the app's envelope", %{user: u, vault: v} do
    note = write!(u, v, "open.md", "secret body")
    {:ok, dek} = Engram.Crypto.get_dek(u)
    aad = Engram.Crypto.aad_for_row(:notes, :content, note.id)

    assert {:ok, "secret body"} =
             Engram.Crypto.Envelope.decrypt(row(note.id)["b_content"], nil, dek, aad)
  end

  test "a content edit rewrites the body; a write without one leaves it alone", %{
    user: u,
    vault: v
  } do
    note = write!(u, v, "edit.md", "one")
    before = row(note.id)

    write!(u, v, "edit.md", "two")
    edited = row(note.id)
    assert edited["b_content"] == merged(edited["content_nonce"], edited["content_ciphertext"])
    refute edited["b_content"] == before["b_content"]

    %{num_rows: 1} =
      Repo.query!("UPDATE notes SET mtime = 42 WHERE id = $1", [Ecto.UUID.dump!(note.id)])

    assert row(note.id)["b_xmin"] == edited["b_xmin"]
  end

  test "the head reset and a head stamp reach the body", %{user: u, vault: v} do
    note = write!(u, v, "head.md", "x")
    head = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    id = Ecto.UUID.dump!(note.id)

    Repo.query!("UPDATE notes SET crdt_head = $2 WHERE id = $1", [id, head])
    assert row(note.id)["b_head"] == Base.url_decode64!(head, padding: false)

    Repo.query!("UPDATE notes SET crdt_head = NULL WHERE id = $1", [id])
    assert row(note.id)["b_head"] == nil
  end

  test "a folder marker gets keys and no body", %{user: u, vault: v} do
    {:ok, _} = Notes.create_folder_marker(u, v, "Marked")

    %{rows: [[is_folder, has_body]]} =
      Repo.query!(
        """
        SELECT n.is_folder, EXISTS (SELECT 1 FROM note_bodies b WHERE b.note_id = n.id)
        FROM notes n WHERE n.vault_id = $1 AND n.kind = 'folder'
        """,
        [Ecto.UUID.dump!(v.id)]
      )

    assert is_folder
    refute has_body
  end

  test "a malformed source derives NULL instead of failing the write", %{user: u, vault: v} do
    note = write!(u, v, "odd.md", "x")
    id = Ecto.UUID.dump!(note.id)

    Repo.query!(
      "UPDATE notes SET content_hash = 'not hex', crdt_head = 'short', link_keys_stamp = '\\x00' WHERE id = $1",
      [id]
    )

    r = row(note.id)
    assert r["content_digest"] == nil
    assert r["b_head"] == nil
    assert r["link_keys_v"] == 0
  end

  test "link_keys_v reads the stamp's Unicode version for the current path", %{
    user: u,
    vault: v
  } do
    note = write!(u, v, "links.md", "x")
    r = row(note.id)
    [major, minor | _] = String.split(Engram.Links.link_keys_version(), ".")
    expected = String.to_integer(major) * 100 + String.to_integer(minor)

    if r["link_keys_stamp"],
      do: assert(r["link_keys_v"] == expected),
      else: assert(r["link_keys_v"] == nil)
  end

  test "a merged column (NULL nonce) is followed by its bytes", %{user: u, vault: v} do
    note = write!(u, v, "merged.md", "x")
    id = Ecto.UUID.dump!(note.id)
    merged = <<1>> <> :crypto.strong_rand_bytes(40)

    Repo.query!(
      "UPDATE notes SET content_ciphertext = $2, content_nonce = NULL WHERE id = $1",
      [id, merged]
    )

    assert row(note.id)["b_content"] == merged

    merged2 = <<1>> <> :crypto.strong_rand_bytes(40)
    Repo.query!("UPDATE notes SET content_ciphertext = $2 WHERE id = $1", [id, merged2])
    assert row(note.id)["b_content"] == merged2
  end

  describe "NoteSplit" do
    test "fills rows written before the triggers, then reports done", %{user: u, vault: v} do
      a = write!(u, v, "a.md", "a")
      b = write!(u, v, "b.md", "b")

      # What a pre-trigger row looks like.
      Repo.query!("DELETE FROM note_bodies WHERE note_id = $1", [Ecto.UUID.dump!(a.id)])

      # Lists no source column, so the derive trigger does not fire.
      Repo.query!("UPDATE notes SET path_id = NULL, is_folder = NULL WHERE id = $1", [
        Ecto.UUID.dump!(b.id)
      ])

      seqs = Enum.map([a, b], &row(&1.id)["seq"])

      assert {:more, rows: 2} = NoteSplit.run_pass()
      assert row(a.id)["has_body"]
      assert row(b.id)["is_folder"] == false
      assert Ecto.UUID.load!(row(b.id)["path_id"]) == id16(row(b.id)["path_hmac"])
      # A catch-up, not a write: no seq moves.
      assert Enum.map([a, b], &row(&1.id)["seq"]) == seqs

      assert :done = NoteSplit.run_pass()
    end

    test "keyset-pages across batches without rescanning", %{user: u, vault: v} do
      notes = for p <- ~w(p1.md p2.md p3.md), do: write!(u, v, p, p)

      for n <- notes do
        Repo.query!("DELETE FROM note_bodies WHERE note_id = $1", [Ecto.UUID.dump!(n.id)])
      end

      # Batches of 2: a full batch, then a short one that ends the pass.
      assert {:more, rows: 3} = NoteSplit.run_pass(batch: 2)
      assert Enum.all?(notes, &row(&1.id)["has_body"])
      assert :done = NoteSplit.run_pass(batch: 2)
    end
  end
end
