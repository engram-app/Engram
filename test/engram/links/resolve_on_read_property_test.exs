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

  property "links and backlinks agree with resolve_target/4" do
    check all(
            notes <- uniq_list_of(note_path(), min_length: 1, max_length: 8),
            atts <- uniq_list_of(att_path(), max_length: 3),
            targets <- list_of(target(), min_length: 1, max_length: 8),
            strip_keys? <- boolean(),
            max_runs: 40
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

      if strip_keys? do
        {:ok, _} =
          Repo.with_tenant(user.id, fn ->
            Repo.update_all(Engram.Notes.Note, set: [path_ci_hmac: nil, path_length: nil])

            Repo.update_all(Engram.Attachments.Attachment,
              set: [path_ci_hmac: nil, path_length: nil]
            )

            Repo.update_all(Engram.Links.NoteLink, set: [target_key_hmac: nil])
          end)
      end

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
