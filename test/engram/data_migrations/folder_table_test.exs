defmodule Engram.DataMigrations.FolderTableTest do
  # The FolderTable data migration: folder rows and `folder_ref_id` for
  # notes, attachments and markers written before the trigger existed.
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Attachments
  alias Engram.Crypto
  alias Engram.Crypto.Envelope
  alias Engram.DataMigrations.FolderTable
  alias Engram.Notes
  alias Engram.Repo

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp dump(id), do: Ecto.UUID.dump!(id)

  defp note!(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    note
  end

  defp attachment!(user, vault, path) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{path: path, content: <<137, 80, 78, 71, 1, 2>>})

    att
  end

  # What the migration finds: rows written before the trigger and the folder
  # rows existed. Wipes both, as a pre-release database would look.
  defp unresolve! do
    Repo.query!("UPDATE notes SET folder_ref_id = NULL")
    Repo.query!("UPDATE attachments SET folder_ref_id = NULL")
    Repo.query!("DELETE FROM folders")
  end

  defp ref(table, id) do
    %{rows: [[ref]]} =
      Repo.query!("SELECT folder_ref_id FROM #{table} WHERE id = $1", [dump(id)])

    ref && Ecto.UUID.load!(ref)
  end

  # path => %{id, explicit}, with the names decrypted the way a reader will.
  defp folder_tree(user) do
    {:ok, dek} = Crypto.get_dek(user)

    %{rows: rows} =
      Repo.query!(
        "SELECT id, parent_id, name_ciphertext, name_nonce, explicit FROM folders WHERE deleted_at IS NULL"
      )

    by_id =
      Map.new(rows, fn [id, parent, ct, nonce, explicit] ->
        id = Ecto.UUID.load!(id)
        {:ok, name} = Envelope.decrypt(ct, nonce, dek, Crypto.aad_for_row(:folders, :name, id))
        {id, %{name: name, parent: parent && Ecto.UUID.load!(parent), explicit: explicit}}
      end)

    path = fn path, id, self ->
      case by_id[id] do
        %{parent: nil, name: n} -> n
        %{parent: p, name: n} -> self.(path, p, self) <> "/" <> n
      end
    end

    Map.new(by_id, fn {id, f} -> {path.(path, id, path), %{id: id, explicit: f.explicit}} end)
  end

  defp run_to_done(opts \\ []) do
    assert {:more, _} = FolderTable.run_pass(opts)
    assert :done = FolderTable.run_pass(opts)
  end

  defp seed!(user, vault) do
    {:ok, marker} = Notes.create_folder_marker(user, vault, "Empty/Deep")

    notes = %{
      root: note!(user, vault, "Root.md"),
      a1: note!(user, vault, "A/N1.md"),
      ab2: note!(user, vault, "A/B/N2.md"),
      ab3: note!(user, vault, "A/B/N3.md"),
      c4: note!(user, vault, "C/N4.md")
    }

    atts = %{
      a: attachment!(user, vault, "A/img.png"),
      deep: attachment!(user, vault, "A/B/C/deep.png"),
      root: attachment!(user, vault, "root.png")
    }

    unresolve!()
    %{marker: marker, notes: notes, atts: atts}
  end

  describe "backfill" do
    test "creates the ancestor chains and points notes, attachments and markers", %{
      user: u,
      vault: v
    } do
      %{marker: marker, notes: n, atts: a} = seed!(u, v)

      run_to_done()

      tree = folder_tree(u)

      assert tree |> Map.keys() |> Enum.sort() ==
               ~w(A A/B A/B/C C Empty Empty/Deep)

      # Only the marker's folder is explicit, and it keeps the marker's UUID.
      assert for({p, %{explicit: true}} <- tree, do: p) == ["Empty/Deep"]
      assert tree["Empty/Deep"].id == marker.id

      assert ref("notes", n.a1.id) == tree["A"].id
      assert ref("notes", n.ab2.id) == tree["A/B"].id
      assert ref("notes", n.ab3.id) == tree["A/B"].id
      assert ref("notes", n.c4.id) == tree["C"].id
      assert ref("notes", n.root.id) == nil
      assert ref("notes", marker.id) == nil

      assert ref("attachments", a.a.id) == tree["A"].id
      assert ref("attachments", a.deep.id) == tree["A/B/C"].id
      assert ref("attachments", a.root.id) == nil
    end

    test "touches no seq, updated_at, body or index-state row", %{user: u, vault: v} do
      seed!(u, v)

      snapshot = fn ->
        %{rows: rows} =
          Repo.query!("""
          SELECT n.id, n.seq, n.updated_at, n.path_id, b.xmin::text, s.xmin::text
          FROM notes n
          LEFT JOIN note_bodies b ON b.note_id = n.id
          LEFT JOIN note_index_state s ON s.note_id = n.id ORDER BY n.id
          """)

        %{rows: att} = Repo.query!("SELECT id, seq, updated_at FROM attachments ORDER BY id")
        {rows, att}
      end

      before = snapshot.()
      run_to_done()
      assert snapshot.() == before
    end

    test "is idempotent: a rerun writes nothing", %{user: u, vault: v} do
      seed!(u, v)
      run_to_done()

      xmins = fn ->
        for t <- ~w(notes attachments folders) do
          %{rows: rows} = Repo.query!("SELECT id, xmin::text FROM #{t} ORDER BY id")
          rows
        end
      end

      before = xmins.()
      assert :done = FolderTable.run_pass()
      assert xmins.() == before
      assert FolderTable.name() == "folder_table"
    end

    test "pages over a small batch", %{user: u, vault: v} do
      for i <- 1..5, do: note!(u, v, "Big/N#{i}.md")
      for i <- 1..5, do: attachment!(u, v, "Big/p#{i}.png")
      unresolve!()

      run_to_done(batch: 2)

      %{rows: [[0]]} =
        Repo.query!("SELECT count(*)::int FROM notes WHERE folder_ref_id IS NULL")

      %{rows: [[0]]} =
        Repo.query!("SELECT count(*)::int FROM attachments WHERE folder_ref_id IS NULL")
    end

    test "touches nothing of another tenant", %{user: u, vault: v} do
      other = insert(:user)
      {:ok, other} = Crypto.ensure_user_dek(other)
      ov = insert(:vault, user: other)
      on = note!(other, ov, "A/X.md")
      oa = attachment!(other, ov, "A/y.png")
      mine = note!(u, v, "A/N.md")
      unresolve!()

      run_to_done(user_ids: [u.id])

      assert ref("notes", mine.id)
      assert ref("notes", on.id) == nil
      assert ref("attachments", oa.id) == nil

      assert %{rows: [[1]]} =
               Repo.query!("SELECT count(*)::int FROM folders WHERE user_id = $1", [dump(u.id)])

      assert %{rows: [[0]]} =
               Repo.query!("SELECT count(*)::int FROM folders WHERE user_id = $1", [
                 dump(other.id)
               ])

      # The other tenant's own pass resolves it into ITS folders only.
      run_to_done(user_ids: [other.id])
      assert ref("notes", on.id) != ref("notes", mine.id)
    end

    test "heals drift: a stale ref, a new folder the old release made, a moved attachment", %{
      user: u,
      vault: v
    } do
      n = note!(u, v, "A/N.md")
      att = attachment!(u, v, "A/img.png")
      unresolve!()
      run_to_done()
      tree = folder_tree(u)

      # The previous release writes a note into a folder that has no row yet
      # (the trigger leaves NULL), and an attachment loses its reference.
      fresh = note!(u, v, "Fresh/Sub/Z.md")
      assert ref("notes", fresh.id) == nil
      Repo.query!("UPDATE attachments SET folder_ref_id = NULL WHERE id = $1", [dump(att.id)])
      Repo.query!("UPDATE folders SET deleted_at = now() WHERE id = $1", [dump(tree["A"].id)])

      run_to_done()

      tree = folder_tree(u)
      assert ref("notes", fresh.id) == tree["Fresh/Sub"].id
      assert ref("attachments", att.id) == tree["A"].id
      assert ref("notes", n.id) == tree["A"].id
    end
  end

  describe "the trigger and the backfill agree" do
    test "a note the backfill resolved is the one the trigger resolves", %{user: u, vault: v} do
      note!(u, v, "A/N.md")
      unresolve!()
      run_to_done()
      later = note!(u, v, "A/Later.md")

      assert ref("notes", later.id) == folder_tree(u)["A"].id
    end
  end

  describe "RLS" do
    test "runs under the enforced app role", %{user: u, vault: v} do
      %{notes: n} = seed!(u, v)

      assert as_prod_role_committing(fn -> FolderTable.run_pass() end) |> elem(0) == :more
      assert as_prod_role_committing(fn -> FolderTable.run_pass() end) == :done
      assert ref("notes", n.a1.id) == folder_tree(u)["A"].id
    end

    test "control: with no tenant the app role finds no folder rows to read", %{user: u, vault: v} do
      seed!(u, v)
      run_to_done()

      assert {:returned, %{rows: [[0]]}} =
               as_prod_role(fn -> Repo.query!("SELECT count(*)::int FROM folders") end)
    end
  end
end
