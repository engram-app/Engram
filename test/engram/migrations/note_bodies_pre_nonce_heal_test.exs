defmodule Engram.Migrations.NoteBodiesPreNonceHealTest do
  @moduledoc """
  Migration 20261110130000 heals the notes the R8(c) owner repair left
  reading empty before its fix (#2545 review MED-1): a pre-nonce note whose
  body column is NULL under its own owner while the `notes` ciphertext
  still holds the envelope. Run as `engram_app` (RLS enforced, no bypass):
  the suite's superuser would pass with an unscoped query too
  (rls-enforcement-testing-traps).
  """
  use Engram.DataCase, async: false

  alias Engram.Notes

  @mod "Elixir.Engram.Repo.Migrations.NoteBodiesPreNonceHealMigrate"

  setup_all do
    Code.require_file(
      "priv/repo/migrations/20261110130000_note_bodies_pre_nonce_heal_migrate.exs"
    )

    :ok
  end

  setup do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Heal", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp write!(u, v, path, content) do
    {:ok, n} = Notes.upsert_note(u, v, %{"path" => path, "content" => content}, actor: "api")
    n
  end

  defp read!(u, v, path) do
    assert {:ok, %{content: content}} = Notes.get_note(u, v, path)
    content
  end

  defp heal!(repo \\ Engram.Repo) do
    Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")

    try do
      String.to_existing_atom(@mod).heal(repo)
    after
      Repo.query!("SET LOCAL SESSION AUTHORIZATION DEFAULT")
    end
  end

  defp content_ct(note) do
    Repo.query!("SELECT content_ct FROM note_bodies WHERE note_id = $1", [
      Ecto.UUID.dump!(note.id)
    ]).rows
  end

  test "a pre-nonce note with a NULL body reads again, under RLS", %{user: u, vault: v} do
    note = write!(u, v, "pre.md", "pre text")
    Engram.Fixtures.pre_nonce_null_body!(note.id)
    assert read!(u, v, "pre.md") == nil

    assert :ok = heal!()
    assert read!(u, v, "pre.md") == "pre text"
  end

  test "CONTROL: a NULL body over a copy with a nonce, and a set body, are left alone", %{
    user: u,
    vault: v
  } do
    kept = write!(u, v, "kept.md", "kept text")
    nonced = write!(u, v, "nonced.md", "nonced text")
    Engram.Fixtures.old_release_notes_copy!(nonced.id)

    Repo.query!("UPDATE note_bodies SET content_ct = NULL WHERE note_id = $1", [
      Ecto.UUID.dump!(nonced.id)
    ])

    before = content_ct(kept)
    assert :ok = heal!()

    assert content_ct(kept) == before
    assert content_ct(nonced) == [[nil]]
  end

  # Raises what DBConnection raises when a window outlives its deadline, for
  # any window wider than one note, and for the one holding note `:never`
  # (every note of the test's user needs healing, so a window of one is the
  # user's next note).
  defmodule SlowRepo do
    @moduledoc false
    defdelegate query!(sql), to: Engram.Repo
    defdelegate query!(sql, params, opts), to: Engram.Repo
    defdelegate transaction(fun, opts), to: Engram.Repo

    def query!(sql, [user, after_id, size] = params) do
      if String.contains?(sql, "UPDATE note_bodies") and too_slow?(user, after_id, size),
        do: raise(DBConnection.ConnectionError, "client timed out"),
        else: Engram.Repo.query!(sql, params)
    end

    def query!(sql, params), do: Engram.Repo.query!(sql, params)

    defp too_slow?(_user, _after_id, size) when size > 1, do: true

    defp too_slow?(user, after_id, _size) do
      Engram.Repo.query!(
        "SELECT id FROM notes WHERE user_id = $1 AND id > $2 AND kind = 'note' ORDER BY id LIMIT 1",
        [user, after_id]
      ).rows == [[:persistent_term.get({__MODULE__, :never}, nil)]]
    end
  end

  defmodule SlowMigration do
    @moduledoc false
    use Ecto.Migration
    @disable_ddl_transaction true
    @disable_migration_lock true

    def up do
      String.to_existing_atom("Elixir.Engram.Repo.Migrations.NoteBodiesPreNonceHealMigrate").heal(
        SlowRepo
      )
    end
  end

  test "a window too slow for its deadline is halved down to one note", %{user: u, vault: v} do
    :persistent_term.put({SlowRepo, :never}, nil)
    notes = for i <- 1..3, do: write!(u, v, "pre#{i}.md", "pre text #{i}")
    Enum.each(notes, &Engram.Fixtures.pre_nonce_null_body!(&1.id))

    assert :ok = heal!(SlowRepo)
    for i <- 1..3, do: assert(read!(u, v, "pre#{i}.md") == "pre text #{i}")
  end

  test "a note too slow even alone: the rest healed, count raised, migration not recorded", %{
    user: u,
    vault: v
  } do
    [stuck | _] = notes = for i <- 1..3, do: write!(u, v, "pre#{i}.md", "pre text #{i}")
    Enum.each(notes, &Engram.Fixtures.pre_nonce_null_body!(&1.id))
    :persistent_term.put({SlowRepo, :never}, Ecto.UUID.dump!(stuck.id))
    version = 99_999_999_999_993

    error =
      assert_raise RuntimeError, fn ->
        Ecto.Migrator.up(Repo, version, SlowMigration, log: false)
      end

    assert error.message =~ "1 note(s) too slow"

    assert Repo.query!("SELECT count(*) FROM schema_migrations WHERE version = $1", [version]).rows ==
             [[0]]

    assert read!(u, v, "pre1.md") == nil
    for i <- 2..3, do: assert(read!(u, v, "pre#{i}.md") == "pre text #{i}")
  end
end
