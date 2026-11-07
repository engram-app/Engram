defmodule Engram.Folders.OpSizeCapTest do
  # #2492: a folder rename or move holds the vault lock for its whole
  # subtree, so one over `:folder_op_max_rows` is refused before any lock,
  # claim or scan. async: false for the global `:storage` mock.
  use Engram.DataCase, async: false

  alias Engram.{Attachments, Folders, Notes, QueryRecorder, Repo, ServiceConfig, Vaults}
  alias Engram.Notes.{CrdtIndexDoc, CrdtIndexPersistence}

  setup do
    prev = Application.get_env(:engram, :storage)
    Application.put_env(:engram, :storage, Engram.MockStorage)
    Mox.stub(Engram.MockStorage, :put, fn _key, _bin, _opts -> :ok end)

    ServiceConfig.put_override(:folder_op_max_rows, 2)
    on_exit(fn -> Application.put_env(:engram, :storage, prev) end)

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    %{user: user, vault: insert(:vault, user: user)}
  end

  defp put_note(user, vault, path) do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => path, "content" => "x"}, actor: "api")

    note
  end

  defp put_att(user, vault, path) do
    {:ok, _} =
      Attachments.upsert_attachment(user, vault, %{
        "path" => path,
        "content_base64" => Base.encode64("x")
      })
  end

  defp snapshot(user, vault) do
    {:ok, notes} = Notes.list_tree_notes(user, vault)
    {:ok, atts} = Attachments.list_attachments(user, vault)

    %{
      seq: Vaults.current_seq(user.id, vault.id),
      notes: notes |> Enum.map(& &1.path) |> Enum.sort(),
      atts: atts |> Enum.map(& &1.path) |> Enum.sort()
    }
  end

  defp claimed_paths(user, vault) do
    {:ok, doc} = CrdtIndexPersistence.load_doc(user, vault.id)
    doc |> Yex.Doc.get_map(CrdtIndexDoc.map_name()) |> Yex.Map.to_map() |> Map.keys()
  end

  defp writes(queries) do
    for %{sql: sql} <- queries,
        sql =~ ~r/^\s*(INSERT|UPDATE|DELETE)\b/i or sql =~ ~r/FOR (NO KEY )?UPDATE/i,
        do: sql
  end

  defp counts(queries), do: Enum.count(queries, &(&1.sql =~ ~r/SELECT count\(/i))

  test "an over-cap rename changes nothing and says how big the folder is", %{
    user: u,
    vault: v
  } do
    put_note(u, v, "A/x.md")
    put_note(u, v, "A/sub/y.md")
    put_att(u, v, "A/a.png")
    before = snapshot(u, v)

    {result, queries} = QueryRecorder.record(fn -> Folders.rename(u, v, "A", "B") end)

    assert result == {:error, {:folder_too_large, 2}}
    assert writes(queries) == [], "wrote before refusing: #{inspect(writes(queries))}"
    assert snapshot(u, v) == before
    refute Enum.any?(claimed_paths(u, v), &String.starts_with?(&1, "B/"))
  end

  test "a drift note (no folder reference) under the folder still counts", %{user: u, vault: v} do
    put_note(u, v, "A/x.md")
    put_note(u, v, "A/y.md")
    z = put_note(u, v, "A/z.md")

    Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE id = $1", [
      Ecto.UUID.dump!(z.id)
    ])

    assert {:error, {:folder_too_large, 2}} = Folders.rename(u, v, "A", "B")
  end

  test "an over-cap batch move sums every selected folder and changes nothing", %{
    user: u,
    vault: v
  } do
    {:ok, a} = Notes.create_folder_marker(u, v, "A")
    {:ok, b} = Notes.create_folder_marker(u, v, "B")
    {:ok, _} = Notes.create_folder_marker(u, v, "Dst")
    put_note(u, v, "A/x.md")
    put_att(u, v, "B/b.png")
    put_note(u, v, "B/y.md")
    before = snapshot(u, v)

    {result, queries} =
      QueryRecorder.record(fn -> Folders.batch_move(u, v, [a.id, b.id], {:path, "Dst"}) end)

    assert result == {:error, {:folder_too_large, 2}}
    assert writes(queries) == [], "wrote before refusing: #{inspect(writes(queries))}"
    assert snapshot(u, v) == before
  end

  test "the count stops reading once the folder is over the cap", %{user: u, vault: v} do
    for p <- ~w(A/x.md A/y.md A/z.md A/w.md), do: put_note(u, v, p)
    put_att(u, v, "A/a.png")

    {result, queries} = QueryRecorder.record(fn -> Folders.rename(u, v, "A", "B") end)

    assert result == {:error, {:folder_too_large, 2}}
    # One bounded notes count (limit + 1 = 3 rows at most); the attachment
    # count never runs.
    assert [%{sql: sql, params: params}] = Enum.filter(queries, &(&1.sql =~ ~r/count\(/i))
    assert sql =~ ~r/LIMIT/i
    assert 3 in params
  end

  test "drift in another folder does not refuse a small folder", %{user: u, vault: v} do
    ServiceConfig.put_override(:folder_op_max_rows, 200)
    for i <- 1..5, do: put_note(u, v, "Small/n#{i}.md")
    # One bulk insert (real envelopes, no folder row for Other), not 300 upserts.
    drift =
      u
      |> Engram.Fixtures.insert_notes!(v, for(i <- 1..300, do: %{"path" => "Other/d#{i}.md"}))
      |> Enum.map(&Ecto.UUID.dump!/1)

    %{num_rows: 300} =
      Repo.query!("UPDATE notes SET folder_ref_id = NULL WHERE id = ANY($1)", [drift])

    assert {:ok, %{notes: 5}} = Folders.rename(u, v, "Small", "Renamed")
  end

  test "at the cap a rename runs, and the check costs the same statements at any size", %{
    user: u,
    vault: v
  } do
    put_note(u, v, "One/x.md")
    put_note(u, v, "Two/x.md")
    put_att(u, v, "Two/a.png")

    {r1, q1} = QueryRecorder.record(fn -> Folders.rename(u, v, "One", "One2") end)
    {r2, q2} = QueryRecorder.record(fn -> Folders.rename(u, v, "Two", "Two2") end)

    assert {:ok, %{notes: 1, attachments: 0}} = r1
    assert {:ok, %{notes: 1, attachments: 1}} = r2
    assert counts(q1) == counts(q2)
    assert snapshot(u, v).notes == ["One2/x.md", "Two2/x.md"]
  end

  test "MCP rename_folder refuses an over-cap folder with the web app's text", %{
    user: u,
    vault: v
  } do
    for p <- ~w(A/x.md A/y.md A/z.md), do: put_note(u, v, p)

    assert Engram.MCP.Handlers.handle("rename_folder", u, v, %{
             "old_folder" => "A",
             "new_folder" => "B"
           }) ==
             {:error,
              {:folder_too_large,
               "Folder too large to rename here (more than 2 items). Rename it in Obsidian."}}
  end
end
