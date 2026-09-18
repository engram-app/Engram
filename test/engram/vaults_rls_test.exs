defmodule Engram.VaultsRlsTest do
  @moduledoc """
  Pins the two unscoped `Engram.Vaults` reads against an ENFORCED row-level
  security policy.

  ## What breaks

  Three sites, two functions, and in both cases the moduledoc asserted the
  explicit `user_id == ^user_id` clause was "the sole guarantee" and that RLS
  was bypassed "for performance". That reasoning inverts the actual order of
  operations: **RLS filters first**, so under a role the policy applies to the
  app-level predicate never gets the chance to be correct.

    * `list_for_ids/2` reads `vaults`. Filtered it returns `%{}`. Its only
      caller is `Engram.Search.load_candidate_vaults/3` (cross-vault search),
      and `search.ex` opens no `with_tenant` anywhere — so every cross-vault
      search result loses the vault it belongs to.
    * `do_content_counts/2` reads `notes` and `attachments`. Filtered both
      return `[]`, and the function's own `Map.new/2` fallback then reports
      `%{notes: 0, attachments: 0}` for every vault. Both callers are HTTP
      request paths in `vaults_controller.ex` (`index/2` and
      `index_payload/2`), which open no `with_tenant` either — so the vault
      list renders every vault as empty.

  The zero-fallback is what makes the second one invisible: the caller cannot
  distinguish "counted zero" from "read nothing", because the function
  manufactures the same shape either way.

  `count_for/1` twenty lines up is already scoped and its comment says exactly
  why — "`vaults` is FORCE-RLS, so the unscoped form counted 0 for every user
  on prod even though `scoped(user_id)` makes the app-level predicate correct
  — RLS filters first. 'The query looks right' is not evidence here." These
  sites are the same bug the same file already documents.

  ## Deliberately NOT changed

  `accessible_vault_ids/1` also carries `skip_tenant_check: true`, but it reads
  `api_key_vaults`, which is not in `Repo.tenant_tables/0` and carries no
  policy. Scoping it would be cargo-culting.

  ## Harness notes

  Neither function opens a `with_tenant/2`, and neither do their callers, so no
  leaked tenant can mask this — the harness's own tenant clear is the only
  state that matters. Rolling-back harness: both assertions are about RETURNED
  values, not persisted effects.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Engram.RlsCase

  alias Engram.Repo
  alias Engram.Vaults
  alias Engram.Vaults.Vault

  setup do
    # `user_with_dek_fixture/1` + `insert_note!/3`: a real note (kind "note",
    # which `do_content_counts/2` filters on) needs a DEK to encrypt its path.
    # Same pattern as `links_rls_test.exs`.
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    vault = insert(:vault, user: user)

    note = Engram.Fixtures.insert_note!(user, vault, %{path: "Counted.md"})
    attachment = insert(:attachment, user: user, vault: vault)

    %{user: user, vault: vault, note: note, attachment: attachment}
  end

  describe "Engram.Vaults under enforced RLS" do
    # CONTROL. Without it a green file cannot distinguish "correctly scoped"
    # from "the role drop never engaged".
    test "control: the dropped role cannot see the user's vault", %{vault: vault} do
      assert {:returned, 0} =
               as_prod_role(fn ->
                 Repo.one(
                   from(v in Vault, where: v.id == ^vault.id, select: count(v.id)),
                   skip_tenant_check: true
                 )
               end)
    end

    test "list_for_ids/2 returns the vault rather than an empty map",
         %{user: user, vault: vault} do
      vault_id = to_string(vault.id)

      outcome = as_prod_role(fn -> Vaults.list_for_ids(user, [vault_id]) end)

      assert {:returned, %{^vault_id => %Vault{}}} = outcome,
             """
             list_for_ids/2 came back empty for a vault the user owns — the read
             was filtered by the policy. Its caller is cross-vault search, so
             every result loses the vault it belongs to.

               got: #{inspect(outcome)}
             """
    end

    test "content_counts_for/2 counts the note and the attachment",
         %{user: user, vault: vault} do
      outcome = as_prod_role(fn -> Vaults.content_counts_for(user, [vault]) end)

      assert {:returned, counts} = outcome
      got = Map.get(counts, vault.id)

      assert got == %{notes: 1, attachments: 1},
             """
             content_counts_for/2 reported #{inspect(got)} for a vault holding one
             note and one attachment — both reads were filtered, and the
             function's own zero-fallback then manufactured a plausible answer.
             The vault list renders every vault as empty.
             """
    end
  end
end
