defmodule Engram.RebuildRlsTest do
  @moduledoc """
  `rebuild_manifest` and `rebuild_manifest_vaults` under an ENFORCED policy
  (`engram_app`), per docs/context/rls-enforcement-testing-traps.md. Each
  Rebuild read and write gets its own test (one scoped statement proves
  nothing about the next), and the CONTROL shows the role drop engages.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Rebuild
  alias Engram.Repo

  setup do
    Engram.Cache.clear_local(:rebuild)
    # `seal/0` runs only in dry_run.
    Engram.ServiceConfig.put_override(:write_v5_layout, true)
    Engram.ServiceConfig.put_override(:index_rebuild, "dry_run")
    user = insert(:user)
    vault = insert(:vault, user: user)
    note = insert(:note, user: user, vault: vault)
    %{user: user, vault: vault, note: note}
  end

  defp row(note, vault, est \\ 60_000),
    do: %{
      note_id: note.id,
      vault_id: vault.id,
      est_tokens: est,
      new_points: 3,
      reused_points: 1,
      mean_pooled_points: 0,
      dl_sum: 30,
      dl_count: 3
    }

  defp count(table),
    do: Repo.query!("SELECT count(*) FROM #{table}").rows |> hd() |> hd()

  defp seed(%{user: user, vault: vault, note: note}) do
    :ok = Rebuild.put_manifest(user.id, [row(note, vault)])
    {:ok, _budget} = Rebuild.seal()
    # Precondition: the superuser sees both rows.
    assert {count("rebuild_manifest"), count("rebuild_manifest_vaults")} == {1, 1}
  end

  test "CONTROL: engram_app with no tenant set sees zero rows", ctx do
    seed(ctx)

    assert {:returned, {0, 0}} =
             as_prod_role(fn -> {count("rebuild_manifest"), count("rebuild_manifest_vaults")} end)
  end

  test "put_manifest writes under the owner's tenant", ctx do
    %{user: user, vault: vault, note: note} = ctx

    assert {:returned, 1} =
             as_prod_role(fn ->
               :ok = Rebuild.put_manifest(user.id, [row(note, vault)])
               Repo.with_tenant!(user.id, fn -> count("rebuild_manifest") end)
             end)
  end

  test "seal reads the owner's manifest and writes its vault avgdl (persisted, committed)",
       ctx do
    %{user: user, vault: vault, note: note} = ctx
    :ok = Rebuild.put_manifest(user.id, [row(note, vault)])

    budget = as_prod_role_committing(fn -> Rebuild.seal() end)

    # 1.15 x 60_000: the manifest was read, not filtered to nothing.
    assert budget == {:ok, 69_000}
    assert [[10.0]] = Repo.query!("SELECT avgdl FROM rebuild_manifest_vaults").rows
  end

  test "pinned_avgdl reads the owner's row (unscoped it would be filtered to nil)", ctx do
    seed(ctx)

    assert {:returned, 10.0} =
             as_prod_role(fn -> Rebuild.pinned_avgdl(ctx.user.id, ctx.vault.id) end)
  end

  test "check_note reads the owner's estimate (unscoped it would read 0 and park)", ctx do
    seed(ctx)
    # 60_000 estimated: 80_000 is within 1.5x. With the row filtered away the
    # estimate would be 0 and this would park.
    assert {:returned, :ok} = as_prod_role(fn -> Rebuild.check_note(ctx.note, 80_000) end)
  end

  test "RLS itself: another tenant sees none of the owner's rows", ctx do
    seed(ctx)
    other = insert(:user)

    assert {:returned, {1, 0}} =
             as_prod_role(fn ->
               {Repo.with_tenant!(ctx.user.id, fn -> count("rebuild_manifest") end),
                Repo.with_tenant!(other.id, fn -> count("rebuild_manifest") end)}
             end)
  end

  test "an INSERT with no tenant set is rejected with 42501", ctx do
    assert {:raised, %Postgrex.Error{postgres: %{code: :insufficient_privilege, message: msg}}} =
             as_prod_role(fn ->
               Repo.query!(
                 "INSERT INTO rebuild_manifest_vaults (vault_id, user_id, avgdl) VALUES ($1, $2, 1.0)",
                 [Ecto.UUID.dump!(ctx.vault.id), Ecto.UUID.dump!(ctx.user.id)]
               )
             end)

    assert msg =~ "row-level security"
  end
end
