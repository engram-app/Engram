defmodule Engram.Notes.NameIndexTest do
  use Engram.DataCase, async: false

  import Engram.Fixtures, only: [insert_note!: 3]

  alias Engram.Notes
  alias Engram.Notes.NameIndex

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    insert_note!(user, vault, path: "Projects/Engram.md", title: "Engram", content: "x")
    insert_note!(user, vault, path: "Daily/2026-10-09.md", title: "Thursday", content: "x")
    on_exit(fn -> NameIndex.clear() end)
    %{user: user, vault: vault}
  end

  defp paths(user, vault, q) do
    {:ok, paths, _total} = NameIndex.search(user, vault, q, 100)
    paths
  end

  # Patches arrive as PubSub messages to the owner; give them a moment.
  defp eventually(fun, tries \\ 50) do
    if fun.() or tries == 0,
      do: assert(fun.()),
      else: Process.sleep(20) && eventually(fun, tries - 1)
  end

  test "fuzzy search over paths and titles", %{user: user, vault: vault} do
    assert paths(user, vault, "engr") == ["Projects/Engram.md"]
    assert paths(user, vault, "prjeng") == ["Projects/Engram.md"]
    assert paths(user, vault, "thursday") == ["Daily/2026-10-09.md"]
    assert paths(user, vault, "zzzz") == []
  end

  test "a rename is reflected without a rebuild", %{user: user, vault: vault} do
    assert paths(user, vault, "engr") == ["Projects/Engram.md"]
    {:ok, _} = Notes.rename_note(user, vault, "Projects/Engram.md", "Archive/Memory.md")

    eventually(fn -> paths(user, vault, "memory") == ["Archive/Memory.md"] end)
    assert paths(user, vault, "projects") == []
  end

  test "a new note and a delete are reflected", %{user: user, vault: vault} do
    assert paths(user, vault, "daily") == ["Daily/2026-10-09.md"]

    {:ok, _} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "Ideas/Fresh.md", "content" => "y", "mtime" => 1.0},
        actor: "api"
      )

    eventually(fn -> paths(user, vault, "fresh") == ["Ideas/Fresh.md"] end)

    _ = Notes.delete_note(user, vault, "Daily/2026-10-09.md")
    eventually(fn -> paths(user, vault, "daily") == [] end)
  end

  test "a burst on a cold vault builds once", %{user: user, vault: vault} do
    me = self()
    handler = "name-index-build-#{inspect(me)}"

    :telemetry.attach(
      handler,
      [:engram, :nif, :call, :stop],
      fn
        _, _, %{nif: :name_index_build}, _ -> send(me, :built)
        _, _, _, _ -> :ok
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    tasks =
      for _ <- 1..10 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Engram.Repo, me, self())
          NameIndex.search(user, vault, "engr", 10)
        end)
      end

    results = Task.await_many(tasks, 30_000)

    assert_received :built
    refute_received :built

    # Only the newest of the waiting searches runs; the rest stand down.
    assert Enum.any?(results, &match?({:ok, ["Projects/Engram.md"], 1}, &1))
    assert Enum.all?(results, &(match?({:ok, _, _}, &1) or &1 == :superseded))
  end

  test "users never see each other's names" do
    other = insert(:user)
    {:ok, other} = Engram.Crypto.ensure_user_dek(other)
    {:ok, ov, _} = Engram.Vaults.register_vault(other, "Other", Ecto.UUID.generate())
    insert_note!(other, ov, path: "Secret/Plan.md", content: "x")

    assert paths(other, ov, "plan") == ["Secret/Plan.md"]
    assert paths(other, ov, "engr") == []
  end

  describe "native" do
    test "batch decrypt matches per-row decrypt, and fails whole on a bad row", %{
      user: user,
      vault: vault
    } do
      rows = Repo.with_tenant!(user.id, fn -> Notes.raw_tree_note_rows(user, vault) end)
      {:ok, dek} = Engram.Crypto.get_dek(user)

      batch = Notes.decrypt_tree_note_rows(rows, dek) |> Enum.map(& &1.path) |> Enum.sort()
      assert batch == ["Daily/2026-10-09.md", "Projects/Engram.md"]

      [{_, raw, v, ct, nonce, _, _} | _] = rows
      prefix = Engram.Crypto.aad_prefix(:notes, :path)
      bound = Engram.Crypto.row_version_aad_bound()

      assert {:ok, [_]} =
               Engram.Crypto.Envelope.decrypt_many(dek, prefix, [{raw, v >= bound, ct, nonce}])

      assert :error =
               Engram.Crypto.Envelope.decrypt_many(dek, prefix, [
                 {:crypto.strong_rand_bytes(16), true, ct, nonce}
               ])
    end

    test "search and batch decrypt do not leak native memory", %{user: user, vault: vault} do
      {:ok, _, _} = NameIndex.search(user, vault, "engr", 10)
      [{_, _, handle, _, _}] = :ets.lookup(:engram_name_index, vault.id)

      Engram.NativeLeak.assert_no_leak(fn ->
        Engram.Native.name_index_search(handle, "eng", 10)
      end)

      rows = Repo.with_tenant!(user.id, fn -> Notes.raw_tree_note_rows(user, vault) end)
      {:ok, dek} = Engram.Crypto.get_dek(user)
      Engram.NativeLeak.assert_no_leak(fn -> Notes.decrypt_tree_note_rows(rows, dek) end)
    end
  end
end
