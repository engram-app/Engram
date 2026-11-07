defmodule Engram.DataMigrations.NoteNameTest do
  # The `NoteName` ledger (O(1) folder rename plan, S2 migrate-data): fills the
  # name columns a previous release left NULL or stale, in one paced chain of
  # bounded hops (`BackfillNoteNames`), and closes on one clean walk. Red
  # before S2: neither module existed.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Engram.RlsCase

  alias Engram.Attachments
  alias Engram.Crypto
  alias Engram.DataMigrations
  alias Engram.DataMigrations.NoteName
  alias Engram.Folders.Folder
  alias Engram.Notes
  alias Engram.Notes.Name
  alias Engram.Repo
  alias Engram.Workers.BackfillNoteNames

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp note!(user, vault, path) do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => path, "content" => "# T\n\nbody"})
    note
  end

  defp attachment!(user, vault, path) do
    {:ok, att} =
      Attachments.upsert_attachment(user, vault, %{path: path, content: <<137, 80, 78, 71, 1>>})

    att
  end

  # What release D (N-1) leaves: no name at all.
  defp n_minus_1_insert! do
    for t <- ["notes", "attachments"] do
      Repo.query!(
        "UPDATE #{t} SET name_ciphertext = NULL, name_nonce = NULL, name_hmac = NULL, " <>
          "name_ci_hmac = NULL, name_stamp = NULL"
      )
    end

    Repo.query!("UPDATE folders SET name_ci_hmac = NULL, name_stamp = NULL")
  end

  defp name_of(user, table, id) do
    {:ok, dek} = Crypto.get_dek(user)

    case Repo.query!(
           "SELECT name_ciphertext, name_nonce, name_stamp, path_nonce FROM #{table} WHERE id = $1",
           [Ecto.UUID.dump!(id)]
         ) do
      %{rows: [[nil, _, _, _]]} ->
        nil

      %{rows: [[ct, nonce, stamp, path_nonce]]} ->
        if stamp == Name.stamp(path_nonce) do
          {:ok, name} = Name.decrypt(String.to_existing_atom(table), dek, id, ct, nonce)
          name
        else
          :stale
        end
    end
  end

  defp folder_ci(id) do
    %{rows: [[ci, stamp, nonce]]} =
      Repo.query!("SELECT name_ci_hmac, name_stamp, name_nonce FROM folders WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    if stamp == Name.stamp(nonce), do: ci, else: :stale
  end

  # Hops until the chain ends; returns how it ended and how many hops it took.
  defp run_chain(args \\ %{}, opts \\ [], hops \\ 1) do
    case BackfillNoteNames.hop(args, opts) do
      {:next, args} when hops < 100 -> run_chain(args, opts, hops + 1)
      other -> {other, hops}
    end
  end

  test "fills the names a previous release left NULL, then closes", %{user: u, vault: v} do
    root = note!(u, v, "Root.md")
    deep = note!(u, v, "A/B/Deep.md")
    att = attachment!(u, v, "A/img.png")
    n_minus_1_insert!()

    refute NoteName.enabled?() == false
    assert {:more, _} = NoteName.run_pass()
    assert [%{args: args}] = all_enqueued(worker: BackfillNoteNames)
    refute DataMigrations.done?(NoteName.name(), NoteName.version())

    # The walk that fixed rows starts a second walk, which is clean: done.
    assert {:done, 2} = run_chain(args)

    assert name_of(u, "notes", root.id) == "Root.md"
    assert name_of(u, "notes", deep.id) == "Deep.md"
    assert name_of(u, "attachments", att.id) == "img.png"

    {:ok, fk} = Crypto.dek_filter_key(u)

    for {path, %{id: id}} <- Engram.FolderRows.tree(u) do
      assert folder_ci(id) == Folder.name_ci_hmac(fk, path |> String.split("/") |> List.last())
    end

    assert DataMigrations.done?(NoteName.name(), NoteName.version())
  end

  test "heals a name a previous release's rename left stale", %{user: u, vault: v} do
    note = note!(u, v, "A/Old.md")

    %{rows: [old]} =
      Repo.query!(
        "SELECT name_ciphertext, name_nonce, name_hmac, name_ci_hmac, name_stamp FROM notes WHERE id = $1",
        [Ecto.UUID.dump!(note.id)]
      )

    {:ok, _} = Notes.rename_note(u, v, "A/Old.md", "A/New.md")

    # Release D renames: new path, old name columns.
    Repo.query!(
      "UPDATE notes SET name_ciphertext = $2, name_nonce = $3, name_hmac = $4, " <>
        "name_ci_hmac = $5, name_stamp = $6 WHERE id = $1",
      [Ecto.UUID.dump!(note.id) | old]
    )

    assert name_of(u, "notes", note.id) == :stale
    assert {:done, _} = run_chain()
    assert name_of(u, "notes", note.id) == "New.md"
  end

  test "a hop is bounded by its row cap and the next resumes at its cursor", %{
    user: u,
    vault: v
  } do
    notes = for i <- 1..5, do: note!(u, v, "N/#{i}.md")
    n_minus_1_insert!()

    opts = [max_rows: 2, batch_size: 1]
    assert {:next, args} = BackfillNoteNames.hop(%{}, opts)
    assert args["from"]
    assert Enum.count(notes, &(name_of(u, "notes", &1.id) != nil)) == 2

    assert {:next, args} = BackfillNoteNames.hop(args, opts)
    assert Enum.count(notes, &(name_of(u, "notes", &1.id) != nil)) == 4

    assert {:done, _} = run_chain(args, opts)
    assert Enum.all?(notes, &(name_of(u, "notes", &1.id) == Path.basename(&1.path)))
  end

  test "perform paces the chain: the successor is scheduled, not immediate", %{
    user: u,
    vault: v
  } do
    for i <- 1..3, do: note!(u, v, "P/#{i}.md")
    n_minus_1_insert!()
    Engram.ServiceConfig.put_override(:note_name_backfill_max_rows, 1)

    assert :ok = perform_job(BackfillNoteNames, %{})
    assert [job] = all_enqueued(worker: BackfillNoteNames)
    assert job.state == "scheduled"
    assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) == :gt
  end

  test "a row that never decrypts keeps the ledger open and stops the chain", %{
    user: u,
    vault: v
  } do
    good = note!(u, v, "G/good.md")
    bad = note!(u, v, "G/bad.md")
    n_minus_1_insert!()

    Repo.query!("UPDATE notes SET path_ciphertext = '\\x0001'::bytea WHERE id = $1", [
      Ecto.UUID.dump!(bad.id)
    ])

    # One walk fixes the good row, the next finds only the bad one: stop, so
    # an unreadable row costs one walk per runner pass, never a hot loop.
    assert {:stopped, 2} = run_chain()
    assert name_of(u, "notes", good.id) == "good.md"
    assert name_of(u, "notes", bad.id) == nil
    refute DataMigrations.done?(NoteName.name(), NoteName.version())
  end

  test "the kill switch stops the chain and the runner pass", %{user: u, vault: v} do
    note!(u, v, "K/k.md")
    n_minus_1_insert!()
    Engram.ServiceConfig.put_override(:note_name_backfill, false)

    refute NoteName.enabled?()
    assert :ok = perform_job(BackfillNoteNames, %{})
    assert [] = all_enqueued(worker: BackfillNoteNames)
  end

  test "run_pass does not start a second chain while one is in flight", %{user: u, vault: v} do
    note!(u, v, "C/c.md")
    n_minus_1_insert!()
    assert {:more, _} = NoteName.run_pass()
    assert {:more, _} = NoteName.run_pass()
    assert [_] = all_enqueued(worker: BackfillNoteNames)
  end

  describe "RLS" do
    test "control: in another tenant's context the heal reads and writes nothing", %{
      user: u,
      vault: v
    } do
      note = note!(u, v, "R/r.md")
      other = insert(:user)
      n_minus_1_insert!()

      assert {0, false} =
               as_prod_role_committing(fn ->
                 BackfillNoteNames.heal_window(:notes, [note.id], %{repo: Repo, user_id: other.id})
               end)

      assert name_of(u, "notes", note.id) == nil
    end

    test "in the owner's tenant the heal writes the row", %{user: u, vault: v} do
      note = note!(u, v, "R/r.md")
      n_minus_1_insert!()

      assert {1, false} =
               as_prod_role_committing(fn ->
                 BackfillNoteNames.heal_window(:notes, [note.id], %{repo: Repo, user_id: u.id})
               end)

      assert name_of(u, "notes", note.id) == "r.md"
    end
  end
end
