defmodule Engram.Links.RebindHubBasenameTest do
  # Prod incident 2026-10-18: a vault where 733 notes share one basename
  # (`index.md` in every folder) and 1,787 edges target it. Every create of one
  # of those notes runs a rebind over ALL edges x ALL candidates, so the resolve
  # loop must be linear in edges + candidates, and must still pick exactly what
  # `resolve_target/4` picks for every edge shape.
  use Engram.DataCase, async: true

  alias Engram.Links
  alias Engram.Links.NoteLink

  @folders 40

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})

    targets =
      [
        "index",
        "f3/index",
        "F7/INDEX",
        "f7/index.md",
        "missing/index",
        "deep/f1/index"
      ] ++ Enum.map(0..(@folders - 1), &"f#{&1}/index")

    :ok =
      Links.replace_links(
        user,
        vault,
        source.id,
        targets
        |> Enum.with_index()
        |> Enum.map(fn {t, i} ->
          %{target: t, alias: nil, anchor: nil, link_type: "wikilink", position: i}
        end)
      )

    # Every edge above is dangling: no `index` note existed when it was written.
    notes =
      Enum.map(0..(@folders - 1), &"f#{&1}/index.md") ++ ["deep/f1/index.md", "F7/Index.md"]

    by_path =
      Map.new(notes, fn p -> {p, Engram.Fixtures.insert_note!(user, vault, %{path: p}).id} end)

    %{user: user, vault: vault, source: source, targets: targets, by_path: by_path}
  end

  test "every edge binds exactly as resolve_target/4 would", %{
    user: user,
    vault: vault,
    source: source,
    targets: targets
  } do
    assert :ok = Links.bind_danglers_in_vault(user, vault.id, Links.basename_hmac(user, "index"))

    bound = edges_by_position(user, source.id)

    for {target, pos} <- Enum.with_index(targets) do
      expected =
        case Links.resolve_target(user, vault, target, "wikilink") do
          {:note, id} -> id
          :dangling -> nil
        end

      assert bound[pos] == expected, "edge #{inspect(target)} bound to the wrong note"
    end
  end

  test "bare and folder targets pick the expected notes", %{
    user: user,
    vault: vault,
    source: source,
    by_path: by_path
  } do
    assert :ok = Links.bind_danglers_in_vault(user, vault.id, Links.basename_hmac(user, "index"))
    bound = edges_by_position(user, source.id)

    # Bare `index`: shortest path wins, lexicographic tiebreak ("F7" < "f0").
    assert bound[0] == by_path["F7/Index.md"]
    assert bound[1] == by_path["f3/index.md"]
    # Case-insensitive folder match: `f7/index.md` and `F7/Index.md` are distinct
    # live paths that both match; the shorter-then-lexicographic one wins.
    assert bound[2] == by_path["F7/Index.md"]
    assert bound[3] == by_path["F7/Index.md"]
    assert bound[4] == nil
    assert bound[5] == by_path["deep/f1/index.md"]
  end

  defp edges_by_position(user, source_id) do
    {:ok, links} =
      Repo.with_tenant(user.id, fn ->
        Repo.all(from(l in NoteLink, where: l.source_note_id == ^source_id))
      end)

    Map.new(links, &{&1.position, &1.target_note_id})
  end
end
