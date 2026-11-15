defmodule Engram.Links.QualifiedLinksTest do
  # `Links.qualified_links_query/4`: the links to one basename that are, or
  # may be, path-qualified (O(1) folder rename plan S5 gate arm 1,
  # Engram#2523). Derived from the stored keys, not a stored flag: a link is
  # bare iff its `target_key_hmac` is the key of `k`, `k.md` or `k.canvas`
  # (`Links.bare_target_keys/2`). A NULL or stale key is not trusted, so the
  # row counts as possibly qualified.
  use Engram.DataCase, async: true

  import Ecto.Query

  alias Engram.Crypto
  alias Engram.Links
  alias Engram.Links.{Parser, Rewriter}

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})
    %{user: user, vault: vault, source: source}
  end

  # `position` is the link's offset in the note; tests name links by their
  # order in the content instead.
  defp positions(source) do
    %{rows: rows} =
      Repo.query!("SELECT position FROM note_links WHERE source_note_id = $1 ORDER BY position", [
        Ecto.UUID.dump!(source.id)
      ])

    List.flatten(rows)
  end

  # Order indexes of `source`'s links the derived query returns for `key`.
  defp qualified_indexes(user, vault, source, key) do
    order = source |> positions() |> Enum.with_index() |> Map.new()
    user |> qualified_positions(vault, key) |> Enum.map(&Map.fetch!(order, &1))
  end

  # Positions of the links to basename `key` the derived query returns.
  defp qualified_positions(user, vault, key) do
    {:ok, filter_key} = Crypto.dek_filter_key(user)
    hmac = Links.basename_hmac(user, key)

    query =
      user.id
      |> Links.qualified_links_query(vault.id, hmac, Links.bare_target_keys(filter_key, key))
      |> select([l], l.position)
      |> order_by([l], l.position)

    Repo.with_tenant!(user.id, fn -> Repo.all(query, skip_tenant_check: true) end)
  end

  defp write!(user, vault, source, content),
    do: :ok = Links.replace_links(user, vault, source.id, Parser.extract(content))

  defp set_row!(source, index, sql) do
    Repo.query!(
      "UPDATE note_links SET #{sql} WHERE source_note_id = $1 AND position = $2",
      [Ecto.UUID.dump!(source.id), Enum.at(positions(source), index)]
    )
  end

  test "returns qualified links and excludes bare ones", ctx do
    write!(
      ctx.user,
      ctx.vault,
      ctx.source,
      "[[Note]] [[Folder/Note]] [[note.md]] [x](../Note.md) [[NOTE.canvas]] [y](Note.md) [[a/b/Note.md]] [[Other]]"
    )

    assert qualified_indexes(ctx.user, ctx.vault, ctx.source, "note") == [1, 3, 6]
  end

  test "agrees with qualified?/1 for every parsed link", ctx do
    content =
      "[[Note]] [[Folder/Note]] ![[img.png]] ![[assets/img.png]] [x](Folder%2FNote.md) " <>
        "[x](My%20Note.md) [[./Note]] [[/Note]] [[Note.md.md]] [[NOTE]]"

    parsed = Parser.extract(content)
    write!(ctx.user, ctx.vault, ctx.source, content)

    for key <- parsed |> Enum.map(&Links.basename_key(&1.target)) |> Enum.uniq() do
      expected =
        for p <- parsed,
            Links.basename_key(p.target) == key,
            Links.qualified?(p.target),
            do: p.position

      assert qualified_positions(ctx.user, ctx.vault, key) == expected, "basename #{key}"
    end
  end

  test "anchors and aliases do not qualify a bare target", ctx do
    write!(
      ctx.user,
      ctx.vault,
      ctx.source,
      "[[Note|a/b]] [[Note#a/b]] [[Note#h|x/y]] [[Folder/Note#Heading|alias]] ![[Note#^blk]]"
    )

    assert qualified_indexes(ctx.user, ctx.vault, ctx.source, "note") == [3]
  end

  test "a row with a NULL target key counts as possibly qualified", ctx do
    write!(ctx.user, ctx.vault, ctx.source, "[[Note]] [[Note.md]]")
    set_row!(ctx.source, 0, "target_key_hmac = NULL")

    assert qualified_indexes(ctx.user, ctx.vault, ctx.source, "note") == [0]
  end

  test "a row with a stale keys stamp counts as possibly qualified", ctx do
    write!(ctx.user, ctx.vault, ctx.source, "[[Note]] [[Note.md]]")
    # A stamp from another nonce or Unicode version: the key is not trusted.
    set_row!(ctx.source, 1, "link_keys_stamp = '\\x00'::bytea")

    assert qualified_indexes(ctx.user, ctx.vault, ctx.source, "note") == [1]
  end

  test "other basenames, vaults and users are not returned", ctx do
    write!(ctx.user, ctx.vault, ctx.source, "[[Other/Thing]] [[Folder/Note]]")
    other_vault = insert(:vault, user: ctx.user)
    other_source = Engram.Fixtures.insert_note!(ctx.user, other_vault, %{path: "S.md"})
    write!(ctx.user, other_vault, other_source, "[[X/Note]]")

    assert qualified_indexes(ctx.user, ctx.vault, ctx.source, "note") == [1]
    assert qualified_indexes(ctx.user, other_vault, other_source, "note") == [0]
  end

  # The query is gate arm 1 only. A bare `[[Guide]]` to a moved note whose
  # basename collides with a sibling is not returned, yet the rewriter
  # rewrites it (`collision?`), so S5 also needs the collision arm. Goes red
  # if either half changes.
  test "a bare link to a moved note with a colliding basename: not returned, still rewritten",
       %{user: user, vault: vault, source: source} do
    moved = Engram.Fixtures.insert_note!(user, vault, %{path: "archive-long/Guide.md"})
    _sibling = Engram.Fixtures.insert_note!(user, vault, %{path: "other/Guide.md"})
    full = "see [[Guide]]"
    write!(user, vault, source, full)

    assert qualified_positions(user, vault, "guide") == []

    {:ok, target} = Rewriter.build_target(user, vault, :note, moved.id, "d/Guide.md")
    assert target.collision?

    edits = Rewriter.plan_edits(user, vault, full, full, target)
    assert edits != []
    assert Rewriter.splice(full, edits) == "see [[archive-long/Guide]]"
  end
end
