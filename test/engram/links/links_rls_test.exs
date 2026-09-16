defmodule Engram.Links.LinksRlsTest do
  @moduledoc """
  Pins `Engram.Links`' public API against an ENFORCED row-level security policy.

  ## What this is about

  `note_links` carries FORCE ROW LEVEL SECURITY, as do the `notes` and
  `attachments` tables these functions join against. Every query in
  `Engram.Links` passes `skip_tenant_check: true`, which suppresses only
  Engram's own guard in `Repo.prepare_query/3` — it sets no tenant in Postgres.

  Unscoped, under any role without SUPERUSER or BYPASSRLS:

    * reads return ZERO ROWS — a note renders with no links and no backlinks,
      and `live_basename_count/3` answers 0 for a basename that is in use
    * `update_all`/`delete_all` are FILTERED by the policy's USING clause and
      report 0 rows affected, with no error
    * only `insert_all` raises (42501) — covered separately in
      `commit_index_rls_test.exs`

  The silent read is the more damaging half, and it is invisible from the
  application's side: the query succeeds.

  ## Why the rest of the suite does not catch this

  `links_test.exs` covers all of these functions' behaviour thoroughly and
  passes — as the SUPERUSER the test database connects as, which bypasses RLS
  even when it is FORCED. Correct behaviour there says nothing about
  enforcement. This file drops to `engram_app` (created by
  `mix engram.prepare_database`, which both the `mix test` alias and CI run;
  no SUPERUSER, no BYPASSRLS) so the policy actually applies.

  ## The tenant-leak trap

  `Engram.Fixtures.insert_note!/3` writes through `Repo.with_tenant/2`, which
  sets `app.current_tenant` with `set_config(..., true)` — SET LOCAL — and
  whose exit path resets only the ROLE, never the tenant. Under the Ecto
  sandbox the whole test runs inside ONE outer transaction, so that tenant
  persists into everything after it.

  `as_prod_role/1` therefore clears the tenant explicitly. Without that line
  the control below sees rows, every assertion in this file holds trivially,
  and the file guards nothing.

  `async: false` because the role change is connection-global.
  """

  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.Crypto.DekCache
  alias Engram.Links
  alias Engram.Links.NoteLink
  alias Engram.Links.Parser
  alias Engram.Repo

  setup do
    # `user_with_dek_fixture/1`, not `insert(:user)`: `replace_links/4` needs a
    # DEK to encrypt each edge's target text, and a bare factory user has none.
    # `Fixtures.insert_note!/3` would create one as a side effect, but the
    # `user` struct here would still be the stale pre-DEK copy — which fails
    # `replace_links/4` with `{:error, :no_dek}` in setup and takes every test
    # in the file down with it. Same pattern as `links_test.exs`.
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    source = Engram.Fixtures.insert_note!(user, vault, %{path: "Source.md"})
    target = Engram.Fixtures.insert_note!(user, vault, %{path: "Target.md"})

    :ok = Links.replace_links(user, vault, source.id, Parser.extract("See [[Target]]."))

    # Force the edge to be BOUND rather than relying on basename-hmac
    # resolution in the fixture path. `backlinks_for_note/2` filters on
    # `target_note_id`, so a dangling edge would make that test vacuous — it
    # would find nothing whether or not RLS was in play.
    {1, _} =
      from(l in NoteLink, where: l.source_note_id == ^source.id)
      |> Repo.update_all([set: [target_note_id: target.id]], skip_tenant_check: true)

    {:ok, user: user, vault: vault, source: source, target: target}
  end

  # Runs `fun` as the non-BYPASSRLS role with NO tenant set — the shape these
  # functions would run in if the app connected as anything but a superuser.
  #
  # Rolls back unconditionally so the SET LOCAL role and tenant are discarded
  # without a trailing RESET ROLE, which would itself fail with 25P02 if the
  # transaction had been aborted by a raise.
  defp as_prod_role(fun) do
    {:error, outcome} =
      Repo.transaction(fn ->
        Repo.query!("SELECT set_config('app.current_tenant', '', true)")
        Repo.query!("SET LOCAL ROLE engram_app")

        outcome =
          try do
            {:returned, fun.()}
          rescue
            e -> {:raised, e}
          end

        Repo.rollback(outcome)
      end)

    outcome
  end

  # Commit-based variant, for assertions about PERSISTED effect.
  #
  # `as_prod_role/1` rolls back unconditionally, which is right for the read
  # tests — they assert on return values — and mandatory for anything that can
  # raise: an RLS-rejected INSERT aborts the transaction, and a trailing
  # `RESET ROLE` would then fail with 25P02 and mask the original error.
  #
  # But a rollback also discards the write under test, so an assertion that a
  # row is GONE can never pass. Committing is safe on this path specifically
  # because `delete_all`/`update_all` are FILTERED by the policy rather than
  # rejected, so nothing here raises.
  defp as_prod_role_committing(fun) do
    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT set_config('app.current_tenant', '', true)")
        Repo.query!("SET LOCAL ROLE engram_app")

        result = fun.()

        # Reset on the SUCCESS path only, deliberately not in an `after`. If
        # `fun` raises, the transaction is already aborted and `RESET ROLE`
        # would fail with 25P02, replacing the real error with "current
        # transaction is aborted". Letting the raise propagate instead rolls
        # the transaction back, which discards the SET LOCAL role and tenant
        # anyway — so nothing leaks and the original error survives.
        Repo.query!("RESET ROLE")
        result
      end)

    result
  end

  describe "Engram.Links under enforced RLS" do
    # CONTROL. Without this a green file is ambiguous between "correctly
    # scoped" and "the role drop never engaged".
    test "control: the dropped role cannot see the seeded edge", %{source: source} do
      outcome =
        as_prod_role(fn ->
          Repo.one(
            from(l in NoteLink, where: l.source_note_id == ^source.id, select: count(l.id)),
            skip_tenant_check: true
          )
        end)

      assert outcome == {:returned, 0},
             """
             Harness is not engaging RLS, so every assertion in this file is meaningless.

               edges visible as engram_app with no tenant: #{inspect(outcome)} (expected {:returned, 0})

             Either SET LOCAL ROLE did not apply, or the tenant was not cleared
             (see the tenant-leak trap in the moduledoc), or the role has BYPASSRLS.
             """
    end

    test "links_for_note/2 returns the note's edges", %{user: user, source: source} do
      assert {:returned, [_ | _] = links} =
               as_prod_role(fn -> Links.links_for_note(user, source.id) end),
             "links_for_note returned no edges — the read was filtered by RLS, so the note " <>
               "renders as having no outgoing links at all"

      assert length(links) == 1
    end

    test "backlinks_for_note/2 returns the incoming edge", %{user: user, target: target} do
      assert {:returned, [_ | _]} =
               as_prod_role(fn -> Links.backlinks_for_note(user, target.id) end),
             "backlinks_for_note returned nothing — the read was filtered by RLS, so the " <>
               "backlinks panel renders empty for a note that has one"
    end

    test "live_basename_count/3 counts the live note", %{user: user, vault: vault} do
      assert {:returned, count} =
               as_prod_role(fn -> Links.live_basename_count(user, vault, "target") end)

      assert count >= 1,
             "live_basename_count returned #{inspect(count)} for a basename that is in use — " <>
               "a filtered read here feeds rename-collision decisions"
    end

    test "on_note_soft_deleted/2 actually drops the outgoing edge",
         %{user: user, source: source} do
      # Committing harness, deliberately: this assertion is about the row being
      # gone afterwards, and the rolling-back helper would discard the delete.
      assert :ok =
               as_prod_role_committing(fn -> Links.on_note_soft_deleted(user.id, source.id) end)

      # Read back OUTSIDE the dropped role. This is the assertion that matters:
      # the delete is FILTERED rather than rejected, so an unscoped call returns
      # :ok having removed nothing.
      remaining =
        Repo.one(
          from(l in NoteLink, where: l.source_note_id == ^source.id, select: count(l.id)),
          skip_tenant_check: true
        )

      assert remaining == 0,
             "the outgoing edge survived on_note_soft_deleted/2 — the DELETE matched zero rows " <>
               "under RLS and reported success, so a deleted note keeps its edges"
    end

    test "resolve_target/4 resolves to the note rather than dangling",
         %{user: user, vault: vault, target: target} do
      assert {:returned, {:note, id}} =
               as_prod_role(fn -> Links.resolve_target(user, vault, "Target", "wikilink") end),
             "resolve_target/4 came back :dangling — its candidate reads were filtered by RLS, " <>
               "which makes EVERY new wikilink in the product resolve to a broken link with " <>
               "nothing logged"

      assert id == target.id
    end

    test "resolve_target/4 resolves the ATTACHMENT branch too",
         %{user: user, vault: vault} do
      # Separate from the note case: `route_resolution/3` tries attachments
      # FIRST for a non-note extension, so the two branches read different
      # tables through different helpers. The notes half passing says nothing
      # about the attachments half, and an unscoped attachment read means every
      # `![[img.png]]` embed silently dangles.
      att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "img.png"})

      assert {:returned, {:attachment, id}} =
               as_prod_role(fn -> Links.resolve_target(user, vault, "img.png", "embed") end),
             "resolve_target/4 came back :dangling for an attachment that exists — the " <>
               "`attachments` candidate read was filtered by RLS"

      assert id == att.id
    end

    test "pre_rename_candidates/5 finds the COMPETING note, not just the renamed one",
         %{user: user, vault: vault, source: source, target: target} do
      # Assert on the competing candidate specifically. `%{notes: [_ | _]}`
      # would be VACUOUS: `do_pre_rename_candidates/7` prepends the renamed row
      # itself unconditionally for `:note`, so the shape matches even when both
      # candidate reads come back empty. This test passed against unscoped code
      # until that was noticed.
      assert {:returned, %{notes: notes}} =
               as_prod_role(fn ->
                 Links.pre_rename_candidates(user, vault, :note, source.id, "Target.md")
               end)

      assert Enum.any?(notes, fn {id, _path} -> id == target.id end),
             """
             pre_rename_candidates/5 saw only the renamed row, not the competing one.

               candidates: #{inspect(notes)}
               expected to contain: #{inspect(target.id)}

             Unscoped, the competing candidate is invisible and
             pre_rename_winner?/4 answers TRUE unopposed — so occurrences that
             actually resolved to a DIFFERENT note get rewritten. Silent link
             corruption on rename, not an absent rewrite.
             """
    end

    test "bind_danglers_for_hmac/3 actually binds the dangler",
         %{user: user, vault: vault, source: source} do
      # Replace the seeded edge set with a single DANGLING edge, then create its
      # target. This is the state the rebind worker exists to resolve.
      :ok = Links.replace_links(user, vault, source.id, Parser.extract("See [[Later]]."))
      later = Engram.Fixtures.insert_note!(user, vault, %{path: "deep/Later.md"})

      hmac = Links.basename_hmac(user, Links.basename_key("deep/Later.md"))

      # Committing harness: the assertion is about the edge being bound
      # afterwards, which a rollback would discard.
      _ = as_prod_role_committing(fn -> Links.bind_danglers_for_hmac(user, vault, hmac) end)

      bound =
        Repo.one(
          from(l in NoteLink, where: l.source_note_id == ^source.id, select: l.target_note_id),
          skip_tenant_check: true
        )

      assert bound == later.id,
             "the dangler never bound — the edge read returned empty under RLS, the `edges != []` " <>
               "guard short-circuited, and the worker reported :ok. Notes created after a link " <>
               "is written stay permanently unlinked"
    end

    test "on_attachments_soft_deleted/2 actually clears the attachment edge",
         %{user: user, vault: vault, source: source} do
      att = Engram.Fixtures.insert_attachment!(user, vault, %{path: "img.png"})
      :ok = Links.replace_links(user, vault, source.id, Parser.extract("See [[img.png]]."))

      # Force the edge to point at the attachment rather than relying on
      # resolution, so a miss here cannot make the test vacuous.
      {1, _} =
        from(l in NoteLink, where: l.source_note_id == ^source.id)
        |> Repo.update_all(
          [set: [target_attachment_id: att.id, target_note_id: nil]],
          skip_tenant_check: true
        )

      _ =
        as_prod_role_committing(fn -> Links.on_attachments_soft_deleted(user.id, [att.id]) end)

      # Row count FIRST. `Repo.one(select: col)` returns nil for zero rows just
      # as it does for one row with a nil column, so the nil assertion below
      # would also pass if the edge had been DELETED. The contract is
      # flip-to-dangling and KEEP the row, so it can re-bind if an attachment
      # reappears at that path.
      assert Repo.one(
               from(l in NoteLink,
                 where: l.source_note_id == ^source.id,
                 select: count(l.id)
               ),
               skip_tenant_check: true
             ) == 1,
             "the edge row itself is gone — on_attachments_soft_deleted/2 must flip the edge to " <>
               "dangling, not delete it, or a re-uploaded attachment never regains its backlinks"

      still_pointing =
        Repo.one(
          from(l in NoteLink,
            where: l.source_note_id == ^source.id,
            select: l.target_attachment_id
          ),
          skip_tenant_check: true
        )

      assert is_nil(still_pointing),
             "the edge still points at a deleted attachment — the UPDATE was filtered, reported " <>
               "{0, nil} and returned :ok, so embeds render against a dead attachment id"
    end

    # NOTE: a cross-tenant read test was removed from here rather than kept.
    # It never entered a harness, so it never dropped the role, and the
    # in-query `l.user_id == ^user.id` filter satisfied it on its own — it
    # passed against unwrapped code, making it a guard for that filter rather
    # than evidence of tenant scoping, in a file whose whole purpose is
    # enforcement. `links_test.exs:442` already covers cross-tenant reads and
    # is strictly stronger: it queries `Repo.all(NoteLink)` under
    # `with_tenant(other.id)` with NO in-query user filter, so only the policy
    # can produce the empty result.
  end

  describe "DEK derivation transaction shape" do
    # Every RLS test above passes whether the DEK is derived inside or outside
    # the tenant scope — they exercise scoping only. This pins the OTHER
    # invariant the fix rests on, the one
    # `docs/context/rls-enforcement-testing-traps.md` states: external I/O must
    # sit OUTSIDE the `with_tenant` scope.
    #
    # Without it, the natural cleanup — re-inlining
    # `{:ok, dek} = Crypto.get_dek(user)` into the `do_*` body, since a
    # threaded parameter reads as noise — silently restores the defect. Under
    # `KEY_PROVIDER=aws_kms` with a cold DekCache, every single-note response
    # would then hold a pooled Postgres connection across a KMS HTTPS round
    # trip, `:kms_throttled` included.
    #
    # Probed through `DekCache`'s hit/miss telemetry rather than a stub
    # provider, because `get_dek/1` dispatches on the blob's provider tag
    # (`KeyProvider.identify_from_blob/1`), not on `config :engram,
    # :key_provider` — swapping the config would not intercept a Local-wrapped
    # blob. A cache MISS is precisely the lookup that reaches the provider, so
    # it is the one whose transaction state matters.
    #
    # Same shape as `attachments_test.exs:128`, which pins the S3 PUT outside
    # the row transaction.
    test "a DEK cache miss never happens inside a transaction",
         %{user: user, source: source} do
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, :dek_probe},
        [:engram, :crypto, :dek_cache],
        fn _event, _measurements, %{outcome: outcome}, _config ->
          send(test_pid, {:dek_lookup, outcome, Repo.in_transaction?()})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, :dek_probe}) end)

      # Force the miss. Setup warmed the cache, and a hit reaches no provider,
      # so without this the test would prove nothing.
      :ok = DekCache.invalidate(user.id)

      _ = Links.links_for_note(user, source.id)

      lookups = drain_dek_lookups([])

      assert lookups != [],
             "no DekCache lookup was observed at all — either the probe is not attached or " <>
               "links_for_note/2 no longer derives a DEK, and this test proves nothing"

      in_txn_misses = for {:miss, true} <- lookups, do: :miss

      assert in_txn_misses == [],
             """
             A DEK cache miss ran INSIDE a transaction, so the provider unwrap holds a
             pooled connection for its duration. Under KEY_PROVIDER=aws_kms that is a
             KMS network RPC, on the hot read path.

               observed lookups (outcome, in_transaction?): #{inspect(lookups)}

             Derive the key at the public entry point, before `Repo.with_tenant/2`,
             and thread it into the private `do_*` function.
             """
    end
  end

  # Module level, not inside the describe above: ExUnit rejects `defp` within a
  # `describe` block.
  defp drain_dek_lookups(acc) do
    receive do
      {:dek_lookup, outcome, in_txn} -> drain_dek_lookups([{outcome, in_txn} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
