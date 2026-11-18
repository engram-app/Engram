defmodule Engram.Folders.ExplicitReadsTest do
  # S6 step 4, phase 1 (Engram#2523): folder listings read explicit folders
  # from `folders.explicit`, not from the `kind = 'folder'` marker rows, and
  # an id a listing hands out resolves for the id-keyed folder operations.
  # Writers still insert markers in this release (the previous release reads
  # them), so a marker with no explicit row, or the reverse, only exists here
  # by a raw write: the reverse is what the write stop (phase 2) leaves.
  use Engram.DataCase, async: false

  alias Engram.{FolderRows, Notes, QueryPlan, QueryRecorder, Repo}

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp put_note(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "# T\n\nbody"}, actor: "api")

    note
  end

  # An explicit folder with no marker row: what a writer leaves once markers
  # stop (phase 2). The marker create makes the explicit row; the marker goes.
  defp explicit_without_marker!(user, vault, folder) do
    {:ok, %{folders: [%{id: id}]}} = Notes.create_folder_markers(user, vault, [folder])
    Repo.query!("UPDATE notes SET deleted_at = now() WHERE id = $1", [Ecto.UUID.dump!(id)])
    assert FolderRows.tree(user)[folder].explicit
    id
  end

  defp payload_ids(user, vault),
    do: Map.new(Notes.folders_payload(user, vault), &{&1.name, &1.id})

  describe "listings read folders.explicit" do
    test "an explicit folder with no marker is listed everywhere", %{user: u, vault: v} do
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

    test "control: a self-host whose folder_table ledger is open reads the markers", ctx do
      %{user: u, vault: v} = ctx
      Engram.ServiceConfig.put_override(:folder_table_ledger, :read)
      refute Engram.Folders.Rows.explicit_reads?()

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
end
