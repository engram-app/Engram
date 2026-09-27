defmodule Engram.MCP.HandlersLinksTruncationTest do
  use Engram.DataCase, async: true

  alias Engram.Links
  alias Engram.MCP.Handlers
  alias Engram.Notes

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    {:ok, target} = Notes.upsert_note(user, vault, %{"path" => "Target.md", "mtime" => 1.0})
    %{user: user, vault: vault, target: target}
  end

  defp link_to_target(user, vault, source_path, edge_count) do
    {:ok, source} =
      Notes.upsert_note(user, vault, %{"path" => source_path, "mtime" => 1.0})

    edges =
      for n <- 0..(edge_count - 1) do
        %{target: "Target", alias: nil, anchor: nil, link_type: "wikilink", position: n}
      end

    :ok = Links.replace_links(user, vault, source.id, edges)
  end

  # `Handlers.links_payload/3` (public, `@doc false`) takes a limit
  # explicitly, so this drives the real (small) cap with a handful of real
  # notes instead of manufacturing `Links.backlinks_limit/0` + 1 of them.
  #
  # Regression: `backlinks_more?` used to come from the raw edge count. One
  # source note can carry several edges to the same target (one row per
  # occurrence), while the exposed `backlinks` list is one entry per source.
  # A source that links twice must not, by itself, look like two backlinks.
  test "one source linking twice does not falsely trip truncation at the cap", %{
    user: u,
    vault: v,
    target: target
  } do
    link_to_target(u, v, "SourceA.md", 2)
    link_to_target(u, v, "SourceB.md", 1)

    # 2 unique sources, 3 edges total. limit: 2 is "right at the cap" for
    # unique sources; the old raw-edge-count logic would have seen limit + 1
    # = 3 rows and wrongly reported truncation.
    {links, truncation} = Handlers.links_payload(u, target, 2)

    assert length(links["backlinks"]) == 2
    assert links["links_truncated"] == false
    refute Handlers.format_links(links, truncation) =~ "more"
  end

  test "a third unique source past the cap does trip truncation", %{
    user: u,
    vault: v,
    target: target
  } do
    link_to_target(u, v, "SourceA.md", 2)
    link_to_target(u, v, "SourceB.md", 1)
    link_to_target(u, v, "SourceC.md", 1)

    {links, truncation} = Handlers.links_payload(u, target, 2)

    assert length(links["backlinks"]) == 2
    assert links["links_truncated"] == true

    assert Handlers.format_links(links, truncation) =~
             "Backlinks: SourceA.md, SourceB.md, and more"
  end
end
