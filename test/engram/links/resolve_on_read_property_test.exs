defmodule Engram.Links.ResolveOnReadPropertyTest do
  # Keyed read-time resolution must answer exactly what `resolve_target/4`
  # (every same-name candidate decrypted and ranked) answers, for any vault:
  # shared basenames, case variants, note/canvas/attachment extensions,
  # folder-qualified targets, and rows without the resolution keys.
  use Engram.DataCase, async: true
  use ExUnitProperties

  alias Engram.Fixtures
  alias Engram.Links

  @folders ["", "a/", "A/", "a/b/", "B/", "x/y/"]
  @names ["Hub", "hub", "HUB", "Node.js", "img"]
  @note_exts [".md", ".canvas"]

  defp note_path,
    do:
      gen(all(f <- member_of(@folders), n <- member_of(@names), e <- member_of(@note_exts)),
        do: f <> n <> e
      )

  defp att_path,
    do:
      gen(all(f <- member_of(@folders), n <- member_of(@names), e <- member_of([".png", ".pdf"])),
        do: f <> n <> e
      )

  defp target do
    gen all(
          f <- member_of(@folders),
          n <- member_of(@names),
          e <- member_of(["", ".md", ".MD", ".canvas", ".png", ".md.md"])
        ) do
      f <> n <> e
    end
  end

  # :missing = written before the keys existed. :stale = keys a writer left
  # behind when it re-encrypted without recomputing them: garbage values whose
  # stamp no longer matches, which readers must ignore, never trust.
  # :mixed = each row its own state, so one basename holds current rows
  # beside missing and stale ones (a backfill or rolling deploy midway).
  defp damage_keys(_user, :fresh), do: :ok

  defp damage_keys(user, :mixed) do
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        for schema <- [Engram.Notes.Note, Engram.Attachments.Attachment, Engram.Links.NoteLink],
            id <- Repo.all(from(r in schema, select: r.id)) do
          case Enum.at([:fresh, :missing, :stale], :erlang.phash2(id, 3)) do
            :fresh -> :ok
            state -> damage(schema, from(r in schema, where: r.id == ^id), state)
          end
        end
      end)
  end

  defp damage_keys(user, state) do
    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        for schema <- [Engram.Notes.Note, Engram.Attachments.Attachment, Engram.Links.NoteLink],
            do: damage(schema, schema, state)
      end)
  end

  defp damage(schema, query, state) do
    junk = :crypto.strong_rand_bytes(32)

    set =
      case {schema, state} do
        {Engram.Links.NoteLink, :missing} -> [target_key_hmac: nil, link_keys_stamp: nil]
        {Engram.Links.NoteLink, :stale} -> [target_key_hmac: junk, link_keys_stamp: junk]
        {_, :missing} -> [path_ci_hmac: nil, path_length: nil, link_keys_stamp: nil]
        {_, :stale} -> [path_ci_hmac: junk, path_length: 1, link_keys_stamp: junk]
      end

    Repo.update_all(query, set: set)
  end

  property "links and backlinks agree with resolve_target/4" do
    check all(
            notes <- uniq_list_of(note_path(), min_length: 1, max_length: 8),
            atts <- uniq_list_of(att_path(), max_length: 3),
            targets <- list_of(target(), min_length: 1, max_length: 8),
            keys <- member_of([:fresh, :missing, :stale, :mixed]),
            max_runs: 80
          ) do
      {:ok, user} = Fixtures.user_with_dek_fixture()
      vault = insert(:vault, user: user)

      # Paths are unique exactly, not case-insensitively: `a/Hub.md` beside
      # `A/hub.md` is legal, and the ranking must break that tie.
      rows = Enum.map(notes, &Fixtures.insert_note!(user, vault, %{path: &1}))
      Enum.each(atts, &Fixtures.insert_attachment!(user, vault, %{path: &1}))
      src = Fixtures.insert_note!(user, vault, %{path: "zz/Source.md"})

      :ok =
        Links.replace_links(
          user,
          vault,
          src.id,
          targets
          |> Enum.with_index()
          |> Enum.map(fn {t, i} ->
            %{target: t, alias: nil, anchor: nil, link_type: "wikilink", position: i}
          end)
        )

      damage_keys(user, keys)

      links = Links.links_for_note(user, src.id)

      expected =
        Enum.map(targets, fn t ->
          case Links.resolve_target(user, vault, t, "wikilink") do
            {:note, id} -> {id, nil}
            {:attachment, id} -> {nil, id}
            :dangling -> {nil, nil}
          end
        end)

      assert Enum.map(links, &{&1.target_note_id, &1.target_attachment_id}) == expected

      for row <- [src | rows] do
        want = for {{id, _}, i} <- Enum.with_index(expected), id == row.id, do: i
        got = user |> Links.backlinks_for_note(row.id) |> length()
        assert got == length(want), "backlinks of #{row.path}: #{got} != #{length(want)}"
      end
    end
  end
end
