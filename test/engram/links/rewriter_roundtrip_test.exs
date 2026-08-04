defmodule Engram.Links.RewriterRoundtripTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Links
  alias Engram.Links.{Parser, Rewriter}
  alias Engram.Notes
  alias Engram.Notes.CrdtBridge

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)
    %{user: user, vault: vault}
  end

  test "round trip: extract -> rename -> rewrite -> re-extract gives the same edge set at the new target",
       %{user: user, vault: vault} do
    content = """
    ---
    title: front
    ---
    Intro [[Old]] then ![[Old|pic]] then [[Old#sec]] and [[unrelated]].
    `[[Old]]` stays; so does the fence:
    ```
    [[Old]]
    ```
    """

    {:ok, old} = Notes.upsert_note(user, vault, %{"path" => "Old.md", "content" => "# target"})
    {:ok, source} = Notes.upsert_note(user, vault, %{"path" => "Src.md", "content" => content})
    :ok = Links.replace_links(user, vault, source.id, Parser.extract(content))

    edges_before = Links.links_for_note(user, source.id)

    {:ok, renamed} = Notes.rename_note(user, vault, "Old.md", "sub/Fresh.md")
    assert renamed.id == old.id

    :ok = Rewriter.rewrite_for_note_rename(user, vault, renamed.id, "Old.md")

    edges_after = Links.links_for_note(user, source.id)

    # Same edge COUNT and shape; alias/anchor/link_type preserved verbatim.
    assert length(edges_after) == length(edges_before)

    assert Enum.map(edges_after, &{&1.alias, &1.anchor, &1.link_type}) ==
             Enum.map(edges_before, &{&1.alias, &1.anchor, &1.link_type})

    # Every edge that pointed at the renamed note still does, under new text.
    rewritten = Enum.filter(edges_after, &(&1.target_note_id == renamed.id))
    assert length(rewritten) == 3
    assert Enum.all?(rewritten, &(&1.target_text == "Fresh"))

    # The unrelated edge is untouched.
    assert Enum.any?(edges_after, &(&1.target_text == "unrelated"))
  end

  test "rewrite delta and a concurrent client update converge in both orders", %{
    user: user,
    vault: vault
  } do
    {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})
    base_text = "alpha [[Old]] omega"

    {:ok, %{state: base_state}} = CrdtBridge.merge_plaintext(nil, base_text)

    target = %{
      kind: :note,
      id: renamed.id,
      old_path: "Old.md",
      new_path: "Fresh.md",
      old_basename_hmac: nil,
      collision?: false
    }

    # Author the rewrite delta on copy A.
    {:ok, doc_a} = CrdtBridge.doc_from_state(base_state)
    body_a = CrdtBridge.body_of(doc_a)
    edits = Rewriter.plan_edits(user, vault, CrdtBridge.project_doc(doc_a), body_a, target)
    sv_a = Yex.encode_state_vector!(doc_a)
    :ok = Rewriter.apply_edits!(doc_a, body_a, edits)
    rewrite_delta = Yex.encode_state_as_update!(doc_a, sv_a)

    # Author a concurrent client edit on copy B (insert far from the link).
    {:ok, doc_b} = CrdtBridge.doc_from_state(base_state)
    sv_b = Yex.encode_state_vector!(doc_b)
    text_b = Yex.Doc.get_text(doc_b, CrdtBridge.text_name())
    Yex.Text.insert(text_b, 0, "CLIENT ")
    client_delta = Yex.encode_state_as_update!(doc_b, sv_b)

    # Order 1: rewrite then client.
    {:ok, doc_1} = CrdtBridge.doc_from_state(base_state)
    :ok = Yex.apply_update(doc_1, rewrite_delta)
    :ok = Yex.apply_update(doc_1, client_delta)

    # Order 2: client then rewrite.
    {:ok, doc_2} = CrdtBridge.doc_from_state(base_state)
    :ok = Yex.apply_update(doc_2, client_delta)
    :ok = Yex.apply_update(doc_2, rewrite_delta)

    assert CrdtBridge.body_of(doc_1) == CrdtBridge.body_of(doc_2)
    assert CrdtBridge.body_of(doc_1) == "CLIENT alpha [[Fresh]] omega"
  end

  # Closes Task 4 review C6 (docs/.superpowers/sdd/.../task-4-report.md): the
  # existing "bounded retry converges" test in rewriter_test.exs inserts its
  # concurrent edit at position 0 — never touching the "Old" byte range the
  # rewrite targets — so it can't tell a real reload-and-replan retry apart
  # from one that's been deleted. This test's concurrent edit lands INSIDE
  # the target span itself.
  test "a concurrent client edit landing inside the rewritten span still converges via a fresh replan",
       %{user: user, vault: vault} do
    {:ok, renamed} = Notes.upsert_note(user, vault, %{"path" => "Fresh.md", "content" => "# t"})

    content = "keep [[Old]] here"

    {:ok, source} =
      Notes.upsert_note(user, vault, %{"path" => "Overlap.md", "content" => content})

    :ok = Links.replace_links(user, vault, source.id, Parser.extract(content))
    {:ok, target} = Rewriter.build_target(user, vault, :note, renamed.id, "Old.md")

    # Fires once, between edit-authoring and the roomless head re-check:
    # a real concurrent write lands INSIDE "Old" (between the "O" and "ld"),
    # so the occurrence no longer reads as a link to "Old" once replanned.
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    before_persist = fn ->
      if Agent.get_and_update(agent, fn n -> {n, n + 1} end) == 0 do
        raw = raw_note!(user, source.id)
        {:ok, snapshot} = Engram.Crypto.decrypt_crdt_state(raw, user)
        {:ok, doc} = CrdtBridge.doc_from_state(snapshot)

        {:ok, _} =
          Repo.with_tenant(user.id, fn ->
            Engram.Notes.CrdtPersistence.replay_tail(doc, user, source.id)
          end)

        sv = Yex.encode_state_vector!(doc)
        text = Yex.Doc.get_text(doc, CrdtBridge.text_name())
        # "keep [[Old]] here" -> insert "X" between "O" and "ld": "keep [[OXld]] here".
        old_at = :binary.match(content, "Old") |> elem(0)
        Yex.Text.insert(text, old_at + 1, "X")
        delta = Yex.encode_state_as_update!(doc, sv)

        _ =
          Engram.Notes.CrdtPersistence.update_v1(
            %{user_id: user.id, vault_id: vault.id, note_id: source.id},
            delta,
            nil,
            doc
          )
      end

      :ok
    end

    assert {:ok, :noop} =
             Rewriter.rewrite_source_note(user, vault, source.id, target,
               before_persist: before_persist
             )

    {:ok, text} = Notes.authoritative_content(user, raw_note!(user, source.id))
    # The concurrent edit survives verbatim; the rewrite backs off instead of
    # clobbering an occurrence that no longer resolves to "Old" once replanned
    # against fresh content (a fresh reload-and-replan retry, not a blind
    # re-persist of the stale pre-overlap delta).
    assert text == "keep [[OXld]] here"
  end

  defp raw_note!(user, id) do
    {:ok, raw} = Repo.with_tenant(user.id, fn -> Repo.get(Engram.Notes.Note, id) end)
    raw
  end
end
