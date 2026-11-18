defmodule Engram.Folders.ExplicitReadsTest do
  # S6 step 4, phase 1 (Engram#2523): folder listings read explicit folders
  # from `folders.explicit`, not from the `kind = 'folder'` marker rows, and
  # an id a listing hands out resolves for the id-keyed folder operations.
  # Writers still insert markers in this release (the previous release reads
  # them), so a marker with no explicit row, or the reverse, only exists here
  # by a raw write: the reverse is what the write stop (phase 2) leaves.
  use Engram.DataCase, async: false

  alias Engram.Backfill.IdWindows
  alias Engram.{DataMigrations, FolderRows, Notes, QueryPlan, QueryRecorder, Repo}
  alias Engram.DataMigrations.{ExplicitFolderReconcile, FolderTable}
  alias Engram.Folders.Rows

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp put_note(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    note
  end

  # An explicit folder row with no live marker: what a cascade before #2639
  # left on a row it kept (stale, `ExplicitFolderReconcile` clears it), and
  # what a writer leaves once markers stop (phase 2). The marker create makes
  # the explicit row; the marker goes.
  defp explicit_without_marker!(user, vault, folder) do
    {:ok, %{folders: [%{id: id}]}} = Notes.create_folder_markers(user, vault, [folder])
    Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(id)])
    assert FolderRows.tree(user)[folder].explicit
    id
  end

  defp payload_ids(user, vault),
    do: Map.new(Notes.folders_payload(user, vault), &{&1.name, &1.id})

  describe "listings read folders.explicit" do
    test "listings read the flag: an explicit row with no marker is listed everywhere",
         %{user: u, vault: v} do
      id = explicit_without_marker!(u, v, "Empty/Inner")

      assert {:ok, ["Empty/Inner"]} = Notes.list_explicit_folders(u, v)
      {:ok, counts} = Notes.list_folders_with_counts(u, v)
      assert %{"Empty/Inner" => 0} = Map.new(counts, &{&1.folder, &1.count})
      assert payload_ids(u, v)["Empty/Inner"] == id
      assert {:ok, ["Empty/Inner"]} = Notes.resolve_folder_markers(u, v, [id])
    end

    test "a folder only derived from notes is not explicit", %{user: u, vault: v} do
      put_note(u, v, "Derived/n.md")

      assert {:ok, []} = Notes.list_explicit_folders(u, v)
      assert payload_ids(u, v) == %{"Derived" => nil}
    end

    test "a marker made after its folder's row: the row's id is listed, both ids resolve", ctx do
      %{user: u, vault: v} = ctx
      put_note(u, v, "D/n.md")
      row = FolderRows.tree(u)["D"].id
      {:ok, %{folders: [%{id: marker}]}} = Notes.create_folder_markers(u, v, ["D"])
      assert marker != row

      assert payload_ids(u, v)["D"] == row
      # The previous release listed the marker's id: an SPA still holding it works.
      assert {:ok, ["D", "D"]} = Notes.resolve_folder_markers(u, v, [row, marker])
      assert {:ok, %{notes: [_]}} = Notes.list_folder_notes_by_id(u, v, marker)
      assert {:ok, %{notes: [_]}} = Notes.list_folder_notes_by_id(u, v, row)
    end

    test "a non-explicit folder row's id, a malformed id and another vault's id are not found",
         %{user: u, vault: v} do
      put_note(u, v, "D/n.md")
      derived = FolderRows.tree(u)["D"].id
      other = insert(:vault, user: u)
      elsewhere = explicit_without_marker!(u, other, "X")

      for id <- [derived, "not-a-uuid", elsewhere] do
        assert {:error, {:not_found, ^id}} = Notes.resolve_folder_markers(u, v, [id])
      end
    end

    test "control: a self-host whose ledgers are open reads the markers", ctx do
      %{user: u, vault: v} = ctx
      Engram.ServiceConfig.put_override(:explicit_folders_ledger, :read)
      refute Rows.explicit_reads?()

      explicit_without_marker!(u, v, "NoMarker")
      {:ok, %{folders: [%{id: m}]}} = Notes.create_folder_markers(u, v, ["Marked"])

      assert {:ok, ["Marked"]} = Notes.list_explicit_folders(u, v)
      assert payload_ids(u, v) == %{"Marked" => m}
    end
  end

  # The listing's new statement as the app role, under RLS: the partial
  # index, never a read of the vault's folders.
  test "plan: the explicit read is the partial index under RLS", %{user: u, vault: v} do
    for i <- 1..40, do: put_note(u, v, "F#{i}/n.md")
    {:ok, _} = Notes.create_folder_markers(u, v, ["E1", "E2"])

    {_, queries} = QueryRecorder.record(fn -> Notes.list_explicit_folders(u, v) end)
    me = self()

    [{sql, params}] =
      for %{sql: s, params: p, pid: ^me} <- queries,
          s =~ ~r/FROM "folders".*"explicit"/s,
          do: {s, p}

    %{custom: custom, generic: generic} = QueryPlan.rls_plans(u.id, sql, params)

    for plan <- [custom, generic] do
      assert plan =~ "folders_explicit_live", plan
      refute plan =~ "Seq Scan on folders", plan
    end
  end

  defp reconcile! do
    IdWindows.reset_walk(ExplicitFolderReconcile.name())

    Enum.reduce_while(1..5, nil, fn _, _ ->
      case ExplicitFolderReconcile.run_pass() do
        :done -> {:halt, :done}
        more -> {:cont, more}
      end
    end)
  end

  # The #2639 review, H1: a row a pre-#2639 cascade left explicit with its
  # marker gone must not be listed, and a path delete must clear it.
  describe "stale explicit rows" do
    test "the reconcile clears a row no live marker names, and keeps a marked one", ctx do
      %{user: u, vault: v} = ctx
      explicit_without_marker!(u, v, "Stale")
      {:ok, _} = Notes.create_folder_markers(u, v, ["Kept"])

      assert reconcile!() == :done
      refute FolderRows.tree(u)["Stale"].explicit
      assert {:ok, ["Kept"]} = Notes.list_explicit_folders(u, v)
      # A second walk finds nothing.
      assert reconcile!() == :done
    end

    test "a path delete (DELETE /folders/<path>) clears a stale row", %{user: u, vault: v} do
      explicit_without_marker!(u, v, "Stale")

      assert {:ok, :deleted} = Notes.delete_folder_marker(u, v, "Stale")
      assert {:ok, []} = Notes.list_explicit_folders(u, v)
      assert {:ok, :not_found} = Notes.delete_folder_marker(u, v, "Stale")
    end

    test "the gate waits for both ledgers", %{user: _u} do
      Engram.ServiceConfig.put_override(:explicit_folders_ledger, :read)
      Engram.DataCase.clear_request_caches()
      refute Rows.explicit_reads?()

      for m <- [FolderTable, ExplicitFolderReconcile],
          do: DataMigrations.mark_done(m.name(), m.version())

      Engram.DataCase.clear_request_caches()
      assert Rows.explicit_reads?()
    end

    test "kill switch: off, the reconcile is disabled" do
      Engram.ServiceConfig.put_override(:explicit_folder_reconcile, false)
      refute ExplicitFolderReconcile.enabled?()
    end
  end

  # The #2639 review, M1: the cascade's marker leg clears the flag even when
  # the folder row is kept (here: content, and no rows leg at all).
  test "a cascade that deletes a marker clears the flag on the row it keeps", ctx do
    %{user: u, vault: v} = ctx
    {:ok, _} = Notes.create_folder_markers(u, v, ["K"])
    put_note(u, v, "K/n.md")
    {:ok, rows} = Notes.scan_folders(u, v, ["K"])
    marker_rows = Enum.filter(rows, &(&1.kind == "folder"))

    assert {:ok, %{deleted: 1}} = Notes.delete_scanned(u, v, marker_rows)
    assert {:ok, []} = Notes.list_explicit_folders(u, v)
    {:ok, counts} = Notes.list_folders_with_counts(u, v)
    assert %{"K" => 1} = Map.new(counts, &{&1.folder, &1.count})
  end

  # The #2639 review, L2: the folder counts' explicit leg as the app role.
  test "plan: the counts' explicit leg is the partial index under RLS", %{user: u, vault: v} do
    for i <- 1..40, do: put_note(u, v, "F#{i}/n.md")
    {:ok, _} = Notes.create_folder_markers(u, v, ["E1", "E2"])
    Engram.DataCase.clear_request_caches()

    {_, queries} = QueryRecorder.record(fn -> Notes.list_folders_with_counts(u, v) end)
    me = self()

    [{sql, params}] =
      for %{sql: s, params: p, pid: ^me} <- queries,
          s =~ "UNION ALL" and s =~ ~r/"explicit"/,
          do: {s, p}

    %{custom: custom, generic: generic} = QueryPlan.rls_plans(u.id, sql, params)

    for plan <- [custom, generic] do
      assert plan =~ "folders_explicit_live", plan
      refute plan =~ "Seq Scan on folders", plan
    end
  end

  # The #2649 review, H1: an empty explicit folder with no marker is a bare
  # folder row; every rename and move surface must move it.
  describe "renaming an empty explicit folder with no marker" do
    test "Folders.rename moves it and reports the folder", %{user: u, vault: v} do
      explicit_without_marker!(u, v, "Empty")

      assert {:ok, %{notes: 0, attachments: 0, folders: 1}} =
               Engram.Folders.rename(u, v, "Empty", "Renamed")

      assert {:ok, ["Renamed"]} = Notes.list_explicit_folders(u, v)
    end

    test "MCP rename_folder moves it", %{user: u, vault: v} do
      explicit_without_marker!(u, v, "Empty")

      assert {:ok, _, _} =
               Engram.MCP.Handlers.handle("rename_folder", u, v, %{
                 "old_folder" => "Empty",
                 "new_folder" => "R2"
               })

      assert {:ok, ["R2"]} = Notes.list_explicit_folders(u, v)
    end

    test "a batch move by id moves it", %{user: u, vault: v} do
      id = explicit_without_marker!(u, v, "Empty")
      {:ok, %{folders: [%{id: _}]}} = Notes.create_folder_markers(u, v, ["Into"])

      assert {:ok, _} = Engram.Folders.batch_move(u, v, [id], {:path, "Into"})
      assert {:ok, ["Into", "Into/Empty"]} = Notes.list_explicit_folders(u, v)
    end

    test "control: a bare derived row is still not found over REST/MCP", %{user: u, vault: v} do
      n = put_note(u, v, "D/n.md")
      :ok = Notes.delete_note(u, v, n.path)

      assert {:ok, %{notes: 0, attachments: 0, folders: 0}} =
               Engram.Folders.rename(u, v, "D", "E")

      assert {:error, {:folder_not_found, _}} =
               Engram.MCP.Handlers.handle("rename_folder", u, v, %{
                 "old_folder" => "D",
                 "new_folder" => "E"
               })
    end

    # The #2639 review: an explicit folder of attachments only (images) moves,
    # and the attachments with it; the bare recheck counts notes only.
    test "an explicit folder holding only attachments moves with them", %{user: u, vault: v} do
      explicit_without_marker!(u, v, "Pics")

      {:ok, _} =
        Engram.Attachments.upsert_attachment(u, v, %{
          "path" => "Pics/a.png",
          "content_base64" => Base.encode64("png")
        })

      assert {:ok, %{notes: 0, attachments: 1, folders: 1}} =
               Engram.Folders.rename(u, v, "Pics", "Photos")

      assert {:ok, ["Photos"]} = Notes.list_explicit_folders(u, v)
      {:ok, metas} = Engram.Attachments.list_attachments(u, v)
      assert Enum.map(metas, & &1.path) == ["Photos/a.png"]
    end

    # The #2639 review: content written under the folder after the rename's
    # scan, before its lock. The move sees it under the vault lock and asks
    # for a re-plan, so the note is cascaded, never left at the old path.
    test "a note that lands after the scan is cascaded, not left behind", %{user: u, vault: v} do
      explicit_without_marker!(u, v, "Late")
      put_note(u, v, "Late/n.md")

      assert {:error, :claims_stale} =
               Repo.with_tenant!(u.id, fn ->
                 Rows.move_bare_explicit(u, v.id, "Late", "Moved")
               end)

      assert {:ok, %{notes: 1, folders: 0}} = Engram.Folders.rename(u, v, "Late", "Moved")
      assert {:ok, _} = Notes.get_note(u, v, "Moved/n.md")
    end
  end
end
