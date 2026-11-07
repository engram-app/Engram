defmodule Engram.Folders.WireTest do
  # `folder_changed` plus the old-plugin nudge from every folder surface (REST,
  # MCP, the shared `Engram.Folders` entry points), and nothing at all while
  # the `folder_ops` switch is off: prod must never half-enable it.
  use EngramWeb.ConnCase, async: true

  alias Engram.Folders
  alias Engram.Folders.Rows
  alias Engram.MCP.Handlers
  alias Engram.Repo
  alias Engram.ServiceConfig

  setup :authed_api_conn

  setup %{user: user, vault: vault} do
    :ok = EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")
    {:ok, _} = Folders.create_markers(user, vault, ["A", "B"])
    flush_broadcasts()
    :ok
  end

  defp on!, do: ServiceConfig.put_override(:folder_ops, true)

  defp id_of(user, vault, path),
    do: Repo.with_tenant!(user.id, fn -> Rows.ids_by_path(user, vault.id, [path]) end)[path]

  defp flush_broadcasts do
    receive do
      %Phoenix.Socket.Broadcast{} -> flush_broadcasts()
    after
      0 -> :ok
    end
  end

  # Every broadcast that arrived, as {event, payload}.
  defp broadcasts(acc \\ []) do
    receive do
      %Phoenix.Socket.Broadcast{event: e, payload: p} -> broadcasts([{e, p} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  # The nudge is the `note_changed` form with no id (old plugins answer it with
  # a seq catch-up); the cascade's per-note events all carry one.
  defp nudge?({"note_changed", p}), do: not Map.has_key?(p, "id") and not Map.has_key?(p, :id)
  defp nudge?(_), do: false

  defp folder_changed(events), do: for({"folder_changed", p} <- events, do: p)
  defp nudges(events), do: events |> Enum.filter(&nudge?/1) |> Enum.map(&elem(&1, 1))

  describe "switch off (the default)" do
    test "no surface emits folder_changed or the nudge", %{conn: conn, user: user, vault: vault} do
      conn
      |> post(~p"/api/folders/rename", %{"old_path" => "A", "new_path" => "A2"})
      |> json_response(200)

      {:ok, _, _} =
        Handlers.handle("rename_folder", user, vault, %{"old_folder" => "B", "new_folder" => "B2"})

      {:ok, _} = Folders.create_markers(user, vault, ["C"])
      {:ok, %{folders: [%{id: c}]}} = Folders.create_markers(user, vault, ["D"])
      {:ok, _} = Folders.batch_move(user, vault, [c], {:path, "A2"})
      {:ok, _} = Folders.rename(user, vault, "A2", "A3")

      events = broadcasts()
      assert events != [], "the ops must still broadcast today's events"
      assert folder_changed(events) == []
      assert nudges(events) == []
    end

    test "rename reports no seq", %{user: user, vault: vault} do
      assert {:ok, counts} = Folders.rename(user, vault, "A", "A2")
      refute Map.get(counts, :seq)
    end
  end

  describe "switch on" do
    setup do
      on!()
      :ok
    end

    test "a REST rename emits ONE folder_changed and ONE nudge of the addendum's shape",
         %{conn: conn, user: user, vault: vault} do
      a = id_of(user, vault, "A")
      b = id_of(user, vault, "B")

      conn
      |> post(~p"/api/folders/rename", %{"old_path" => "A", "new_path" => "B/A"})
      |> json_response(200)

      events = broadcasts()
      seq = Engram.Vaults.current_seq(user.id, vault.id)

      assert [changed] = folder_changed(events)

      assert Map.delete(changed, :traceparent) == %{
               folder_id: a,
               parent_id: b,
               name: "A",
               seq: seq,
               deleted: false,
               device_id: nil
             }

      assert [nudge] = nudges(events)
      assert Map.delete(nudge, :traceparent) == %{event_type: "upsert", kind: "note", path: "B/A"}
    end

    test "an MCP rename emits them too", %{user: user, vault: vault} do
      {:ok, _, _} =
        Handlers.handle("rename_folder", user, vault, %{"old_folder" => "A", "new_folder" => "A2"})

      events = broadcasts()
      assert [%{name: "A2", parent_id: nil}] = folder_changed(events)
      assert [%{path: "A2"}] = nudges(events)
    end

    test "a create and a batch move emit one each per folder", %{user: user, vault: vault} do
      {:ok, %{folders: [%{id: c}]}} = Folders.create_markers(user, vault, ["C"])
      assert [%{name: "C", parent_id: nil}] = folder_changed(broadcasts())

      {:ok, _} = Folders.batch_move(user, vault, [c], {:path, "A"})
      events = broadcasts()
      assert [%{name: "C", parent_id: parent}] = folder_changed(events)
      assert parent == id_of(user, vault, "A")
      assert [%{path: "A/C"}] = nudges(events)
    end

    test "rename returns the op's seq", %{user: user, vault: vault} do
      assert {:ok, %{seq: seq}} = Folders.rename(user, vault, "A", "A2")
      assert seq == Engram.Vaults.current_seq(user.id, vault.id)
    end

    test "a nudge path never ends in .md or .canvas", %{user: user, vault: vault} do
      {:ok, _} = Folders.create_markers(user, vault, ["X.md", "Y.canvas", "Z.MD"])
      created = nudges(broadcasts())
      {:ok, _} = Folders.rename(user, vault, "X.md", "B/X2.md")
      moved = nudges(broadcasts())

      assert length(created) == 3
      assert [_] = moved

      for %{path: path} <- created ++ moved do
        assert path != ""
        refute path |> String.downcase() |> String.ends_with?([".md", ".canvas"])
      end
    end
  end
end
