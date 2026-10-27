defmodule Engram.Folders.DescendantsTest do
  # `Folders.descendant_ids/3` and `subtree_filter/2`: a folder's subtree as the
  # row ids a point's `f` holds, expanded at query time.
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Folders
  alias Engram.Folders.Rows
  alias Engram.Repo
  alias Engram.Vector.FilterId

  setup do
    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  defp ensure!(user, vault, folder) do
    {:ok, {:ok, id}} = Repo.with_tenant(user.id, fn -> Rows.ensure(user, vault.id, folder) end)
    id
  end

  test "the folder, its descendants, not siblings or ancestors", %{user: u, vault: v} do
    a = ensure!(u, v, "A")
    b = ensure!(u, v, "A/B")
    c = ensure!(u, v, "A/B/C")
    d = ensure!(u, v, "A/D")
    _other = ensure!(u, v, "Other")

    assert {:ok, ids} = Folders.descendant_ids(v, a)
    assert Enum.sort(ids) == Enum.sort([a, b, c, d])
    assert {:ok, [^c]} = Folders.descendant_ids(v, c)
    assert {:ok, ids} = Folders.descendant_ids(v, b)
    assert Enum.sort(ids) == Enum.sort([b, c])
  end

  test "an unknown root has no subtree", %{user: u, vault: v} do
    assert {:ok, []} = Folders.descendant_ids(v, Ecto.UUID.generate())
    _ = u
  end

  test "another vault's folders are never in the subtree", %{user: u, vault: v} do
    a = ensure!(u, v, "A")
    other = insert(:vault, user: u)
    ensure!(u, other, "A/B")

    assert {:ok, [^a]} = Folders.descendant_ids(v, a)
  end

  test "over the cap it refuses instead of truncating", %{user: u, vault: v} do
    a = ensure!(u, v, "A")
    for n <- 1..3, do: ensure!(u, v, "A/F#{n}")

    assert {:ok, ids} = Folders.descendant_ids(v, a, 4)
    assert length(ids) == 4
    assert {:error, :folder_subtree_too_large} = Folders.descendant_ids(v, a, 3)
  end

  test "a cycle is walked once: no duplicates, never reported as too large", %{user: u, vault: v} do
    a = ensure!(u, v, "A")
    b = ensure!(u, v, "A/B")
    c = ensure!(u, v, "A/B/C")
    d = ensure!(u, v, "A/B/C/D")
    e = ensure!(u, v, "A/B/C/D/E")
    # A 5-folder loop: A is now under E.
    Repo.query!("UPDATE folders SET parent_id = $1 WHERE id = $2", [
      Ecto.UUID.dump!(e),
      Ecto.UUID.dump!(a)
    ])

    task = Task.async(fn -> Folders.descendant_ids(v, a, 5) end)
    assert {:ok, {:ok, ids}} = Task.yield(task, 5_000) || Task.shutdown(task)
    assert Enum.sort(ids) == Enum.sort([a, b, c, d, e])
  end

  test "the caller contract: the refusal has a message and a 422 mapping", %{user: u, vault: v} do
    a = ensure!(u, v, "A")
    for n <- 1..2, do: ensure!(u, v, "A/F#{n}")

    assert {:error, reason} = Folders.descendant_ids(v, a, 2)
    assert is_binary(Engram.Search.input_error_message(reason))
    assert Engram.Search.input_error_message(reason) =~ "subfolders"
  end

  test "subtree_filter matches any of the row ids, undashed", %{user: u, vault: v} do
    a = ensure!(u, v, "A")
    b = ensure!(u, v, "A/B")

    assert {:ok, %{key: "f", match: %{any: any}}} = Folders.subtree_filter(v, a)
    assert Enum.sort(any) == Enum.sort([FilterId.uuid(a), FilterId.uuid(b)])
  end
end
