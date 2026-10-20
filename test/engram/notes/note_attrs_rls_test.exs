defmodule Engram.Notes.NoteAttrsRlsTest do
  @moduledoc """
  `note_attrs` is tenant-isolated by RLS. Every assertion runs as a
  non-superuser role (the suite connects as a superuser, which bypasses RLS
  even when FORCED); the CONTROL proves the harness bites.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Notes.NoteAttr
  alias Engram.Repo
  alias Engram.Vector.FilterId

  @moduletag :rls_unsafe

  setup do
    seeded =
      for _ <- 1..2 do
        user = insert(:user)
        vault = insert(:vault, user: user)
        note = insert(:note, user: user, vault: vault)
        fk = :crypto.strong_rand_bytes(32)

        Repo.insert_all(
          NoteAttr,
          [
            %{
              note_id: note.id,
              user_id: user.id,
              key_hmac: FilterId.key_hmac(fk, "status"),
              value_hmac: FilterId.value_hmac(fk, "draft")
            }
          ],
          skip_tenant_check: true
        )

        %{user: user, fk: fk, note: note}
      end

    {:ok, a: Enum.at(seeded, 0), b: Enum.at(seeded, 1)}
  end

  defp rows, do: Repo.all(NoteAttr, skip_tenant_check: true)

  defp as_tenant(user_id, fun) do
    as_prod_role(fn ->
      Repo.query!("SELECT set_config('app.current_tenant', $1, true)", [to_string(user_id)])
      fun.()
    end)
  end

  test "CONTROL: engram_app with no tenant sees zero rows" do
    assert length(rows()) == 2
    assert as_prod_role(&rows/0) == {:returned, []}
  end

  test "a tenant sees only its own rows; equal values HMAC differently", %{a: a, b: b} do
    assert {:returned, [row]} = as_tenant(a.user.id, &rows/0)
    assert row.user_id == a.user.id
    assert row.key_hmac == FilterId.key_hmac(a.fk, "status")
    refute row.key_hmac == FilterId.key_hmac(b.fk, "status")
    refute row.value_hmac == FilterId.value_hmac(b.fk, "draft")
  end

  test "a tenant cannot write another tenant's row", %{a: a, b: b} do
    {:returned, [_]} = as_tenant(a.user.id, &rows/0)

    assert {:raised, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             as_tenant(a.user.id, fn ->
               Repo.insert_all(
                 NoteAttr,
                 [%{note_id: b.note.id, user_id: b.user.id, key_hmac: "k", value_num: 1.0}],
                 skip_tenant_check: true
               )
             end)
  end

  test "maintenance_all sees every tenant's rows" do
    {:ok, n} =
      Repo.transaction(fn ->
        Repo.query!("SELECT set_config('app.current_tenant', '', true)")
        Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_maintenance")
        n = length(rows())
        Repo.query!("RESET SESSION AUTHORIZATION")
        n
      end)

    assert n == 2
  end
end
