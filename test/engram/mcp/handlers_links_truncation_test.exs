defmodule Engram.MCP.HandlersLinksTruncationTest do
  use Engram.DataCase, async: false

  alias Engram.Links
  alias Engram.MCP.Handlers

  # Backlinks are the one list `Links.backlinks_for_note/3` itself caps in
  # the database (see links.ex), so proving the handler's truncation signal
  # for it end-to-end would otherwise need 200+ real encrypted source notes.
  # `Links.backlinks_limit/0` reads `config :engram, :backlinks_limit`
  # precisely so a test can drive the same cap with a handful of notes
  # instead. `async: false` + on_exit restore mirrors the existing pattern
  # for other global config overrides in this suite (handlers_test.exs,
  # handlers_upload_target_test.exs).
  setup do
    prev = Application.get_env(:engram, :backlinks_limit)
    Application.put_env(:engram, :backlinks_limit, 2)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:engram, :backlinks_limit),
        else: Application.put_env(:engram, :backlinks_limit, prev)
    end)

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  test "backlinks past the (overridden) cap are truncated with an unknown count", %{
    user: u,
    vault: v
  } do
    _target = Engram.Fixtures.insert_note!(u, v, %{path: "Target.md"})

    for n <- 1..3 do
      source = Engram.Fixtures.insert_note!(u, v, %{path: "Source#{n}.md"})

      :ok =
        Links.replace_links(u, v, source.id, [
          %{target: "Target", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
        ])
    end

    assert {:ok, text, %{"notes" => [t]}} =
             Handlers.handle("get_notes", u, v, %{
               "paths" => ["Target.md"],
               "include_links" => true
             })

    assert length(t["backlinks"]) == 2
    assert t["links_truncated"] == true
    assert text =~ "Backlinks: Source1.md, Source2.md, and more"
  end

  test "at or under the (overridden) cap, nothing is marked truncated", %{user: u, vault: v} do
    _target = Engram.Fixtures.insert_note!(u, v, %{path: "Target.md"})
    source = Engram.Fixtures.insert_note!(u, v, %{path: "Source.md"})

    :ok =
      Links.replace_links(u, v, source.id, [
        %{target: "Target", alias: nil, anchor: nil, link_type: "wikilink", position: 0}
      ])

    assert {:ok, text, %{"notes" => [t]}} =
             Handlers.handle("get_notes", u, v, %{
               "paths" => ["Target.md"],
               "include_links" => true
             })

    assert t["backlinks"] == ["Source.md"]
    assert t["links_truncated"] == false
    refute text =~ "more"
  end
end
