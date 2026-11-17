defmodule Engram.Migrations.DropNotesBodyCiphertextColumnsTest do
  @moduledoc """
  Migration 20261118100000 (R8(e)) drops `notes.content_ciphertext` and
  `notes.crdt_state_ciphertext`, gated on no note holding its only body
  copy there (#2402). The suite's database already ran it, so each test
  puts the columns back inside its sandbox transaction (`run_down/1`) and
  builds the legacy state on them. The gate runs as `engram_app` too (RLS
  enforced, no bypass): a superuser would pass an unscoped query
  (rls-enforcement-testing-traps).
  """
  use Engram.DataCase, async: false

  alias Engram.Notes

  # Hands the gate's per-user walk a tenant no note belongs to: the RLS
  # policy then hides every row, as a wrong GUC or a policy change would.
  defmodule WrongTenantRepo do
    @tenant "SELECT set_config('app.current_tenant', $1::uuid::text, true)"
    def query!(sql, params \\ [], opts \\ [])

    def query!(@tenant, [_], opts),
      do: Engram.Repo.query!(@tenant, [Ecto.UUID.dump!(Ecto.UUID.generate())], opts)

    def query!(sql, params, opts), do: Engram.Repo.query!(sql, params, opts)
    def transaction(fun, opts), do: Engram.Repo.transaction(fun, opts)
  end

  defp mod,
    do: Engram.MigrationFile.load!("20261118100000_drop_notes_body_ciphertext_columns_drops.exs")

  setup do
    :ok = Engram.Fixtures.legacy_body_columns!()
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Drop", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp write!(u, v, path) do
    {:ok, n} = Notes.upsert_note(u, v, %{"path" => path, "content" => "text"}, actor: "api")
    n
  end

  defp columns do
    Repo.query!("""
    SELECT attname::text FROM pg_attribute
    WHERE attrelid = 'notes'::regclass AND NOT attisdropped
      AND attname IN ('content_ciphertext', 'crdt_state_ciphertext') ORDER BY 1
    """).rows
    |> List.flatten()
  end

  defp as_app(fun) do
    Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")

    try do
      fun.()
    after
      Repo.query!("SET LOCAL SESSION AUTHORIZATION DEFAULT")
    end
  end

  # The only copy in `notes`, its body column NULL.
  defp only_copy_in_notes!(note, notes_col, body_col) do
    id = Ecto.UUID.dump!(note.id)
    Repo.query!("UPDATE notes SET #{notes_col} = '\\x0102'::bytea WHERE id = $1", [id])
    Repo.query!("UPDATE note_bodies SET #{body_col} = NULL WHERE note_id = $1", [id])
  end

  @both ["content_ciphertext", "crdt_state_ciphertext"]

  test "CONTROL: healthy notes pass, both columns drop, a rerun is a no-op", %{user: u, vault: v} do
    write!(u, v, "ok.md")
    assert columns() == @both
    assert as_app(fn -> mod().unsafe_count(Repo) end) == 0

    assert :ok = mod().run_up(Repo)
    assert columns() == []
    assert :ok = mod().run_up(Repo)
  end

  for {label, notes_col, body_col} <- [
        {"content", "content_ciphertext", "content_ct"},
        {"CRDT state", "crdt_state_ciphertext", "crdt_ct"}
      ] do
    test "a NULL body #{label} with the only copy in notes blocks the drop", %{user: u, vault: v} do
      write!(u, v, "ok.md")
      only_copy_in_notes!(write!(u, v, "bad.md"), unquote(notes_col), unquote(body_col))

      assert as_app(fn -> mod().unsafe_count(Repo) end) == 1

      assert_raise RuntimeError, ~r/1 note\(s\) hold their only body copy/, fn ->
        mod().run_up(Repo)
      end

      assert columns() == @both
    end
  end

  test "a note with no body row blocks the drop, under RLS too", %{user: u, vault: v} do
    note = write!(u, v, "orphan.md")
    Repo.query!("DELETE FROM note_bodies WHERE note_id = $1", [Ecto.UUID.dump!(note.id)])

    assert as_app(fn -> mod().unsafe_count(Repo) end) == 1
    assert_raise RuntimeError, ~r/only body copy/, fn -> mod().run_up(Repo) end
    assert columns() == @both
  end

  test "the per-user walk raises when RLS hides every note the catalog counts", %{
    user: u,
    vault: v
  } do
    write!(u, v, "a.md")
    # Puts this transaction's rows into `reltuples`, the guard's estimate.
    Repo.query!("ANALYZE notes")

    assert_raise RuntimeError, ~r/sees no notes but notes has rows/, fn ->
      as_app(fn -> mod().unsafe_count(WrongTenantRepo) end)
    end
  end

  test "the error names the note and the recovery section", %{user: u, vault: v} do
    note = write!(u, v, "bad.md")
    only_copy_in_notes!(note, "content_ciphertext", "content_ct")

    e = assert_raise RuntimeError, fn -> mod().run_up(Repo) end
    assert e.message =~ note.id
    assert e.message =~ "Recovery: the R8(e) notes body columns drop refused"
    assert columns() == @both
  end
end
