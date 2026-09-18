defmodule Engram.Links.RewriterRlsTest do
  @moduledoc """
  Pins the rename link-rewriter against an ENFORCED row-level security policy.

  ## What breaks, and why it is worse than silent

  Two unscoped reads sit on the rename-rewrite path, and neither is inside a
  `with_tenant/2`:

    * `current_path/4` (both clauses) reads the renamed row from `notes` /
      `attachments`. Filtered, it returns `nil`, so `build_target/5` answers
      `{:error, :target_gone}`.
    * `source_note_ids/5` reads `note_links` for edges pointing at the old
      basename. Filtered, it returns `[]`.

  `Workers.RewriteNoteLinks` maps that first failure to **`{:discard,
  :target_gone}`** — Oban throws the job away as a legitimate terminal state,
  not a retryable error. So every `[[wikilink]]` pointing at a renamed note
  keeps pointing at the old path permanently, and the queue records a clean
  discard rather than a failure. Nothing logs an error and no retry heals it.

  The second read fails the same way independently: even with a valid target,
  zero source notes are found, `rewrite_each/4` does nothing, and the walk
  terminates having rewritten nothing.

  `tombstone_old_path/4` in the worker is already scoped (it carries the
  comment explaining exactly this failure mode), which is what makes the two
  reads here the remaining half of the same bug.

  ## Harness notes

  `build_target/5` evaluates `current_path/4` BEFORE it calls
  `Links.live_basename_count/3` and `Links.pre_rename_candidates/5`, both of
  which open their own `with_tenant/2`. So the unscoped read happens before any
  nested block could leak a tenant forward, and the `with` short-circuits on
  failure — no leak-forward can mask this. See trap 7 in
  `docs/context/rls-enforcement-testing-traps.md`.

  The rolling-back harness is correct here: both assertions are about a
  RETURNED value, not a persisted effect.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.Links
  alias Engram.Links.NoteLink
  alias Engram.Links.Parser
  alias Engram.Links.Rewriter
  alias Engram.Repo

  # Mirrors `Rewriter`'s own module attribute — the walk's first page.
  @start_cursor "00000000-0000-0000-0000-000000000000"

  setup do
    # `user_with_dek_fixture/1` rather than `insert(:user)`: `replace_links/4`
    # needs a DEK to encrypt each edge's target text, and this also warms the
    # DEK cache so the decrypt inside `current_path/4` is not a cold unwrap
    # inside the harness transaction. Same pattern as `links_rls_test.exs`.
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})
    target = Engram.Fixtures.insert_note!(user, vault, %{path: "Target.md"})

    :ok = Links.replace_links(user, vault, source.id, Parser.extract("See [[Target]]."))

    # Computed as the superuser: this is the HMAC the walk keys on, and
    # deriving it is not the thing under test.
    old_basename_hmac = Links.basename_hmac(user, Links.basename_key("Target.md"))

    %{
      user: user,
      vault: vault,
      source: source,
      target: target,
      old_basename_hmac: old_basename_hmac
    }
  end

  describe "the rename rewriter under enforced RLS" do
    # CONTROL. Without it a green file cannot distinguish "correctly scoped"
    # from "the role drop never engaged".
    test "control: the dropped role sees neither the edge nor the renamed note",
         %{source: source, target: target} do
      assert {:returned, {0, 0}} =
               as_prod_role(fn ->
                 edges =
                   Repo.one(
                     from(l in NoteLink,
                       where: l.source_note_id == ^source.id,
                       select: count(l.id)
                     ),
                     skip_tenant_check: true
                   )

                 notes =
                   Repo.one(
                     from(n in Engram.Notes.Note,
                       where: n.id == ^target.id,
                       select: count(n.id)
                     ),
                     skip_tenant_check: true
                   )

                 {edges, notes}
               end)
    end

    test "build_target/5 finds the renamed note instead of reporting :target_gone",
         %{user: user, vault: vault, target: target} do
      outcome =
        as_prod_role(fn -> Rewriter.build_target(user, vault, :note, target.id, "Target.md") end)

      assert {:returned, {:ok, %{new_path: "Target.md"}}} = outcome,
             """
             build_target/5 could not see the renamed note, so `current_path/4`
             was filtered by the policy. The worker maps this to
             {:discard, :target_gone} — the rewrite job is thrown away and every
             inbound link keeps pointing at the old path, with no error anywhere.

               got: #{inspect(outcome)}
             """
    end

    test "source_note_ids/5 finds the referring note instead of an empty page",
         %{user: user, vault: vault, source: source, old_basename_hmac: hmac} do
      outcome =
        as_prod_role(fn ->
          Rewriter.source_note_ids(user, vault, hmac, @start_cursor, 100)
        end)

      assert {:returned, [_ | _] = ids} = outcome,
             """
             source_note_ids/5 returned no source notes for a basename that has
             one referring edge — the `note_links` read was filtered, so the walk
             rewrites nothing and terminates as if the work were done.

               got: #{inspect(outcome)}
             """

      assert source.id in ids
    end
  end
end
