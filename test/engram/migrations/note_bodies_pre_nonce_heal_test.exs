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

  defp heal!(repo \\ Engram.Repo, opts \\ []) do
    Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")

    try do
      mod = String.to_existing_atom(@mod)
      if opts == [], do: mod.heal(repo), else: mod.heal(repo, opts)
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

  # A repo that misbehaves as `plan/1` says:
  #   * `slow_over: n` / `never: id`: a heal window wider than `n` notes, or
  #     a window of one holding note `id` (every note of the test's user
  #     needs healing, so that is the user's next note), fails with `error`:
  #     `:timeout` (the checkout deadline, default), `:canceled` (Postgres
  #     57014 from `statement_timeout`) or `:closed` (a dropped connection).
  #   * `lock_heal: n`: the first `n` heal windows hit a lock timeout.
  #   * `probe_fail: {n, code}`: the first `n` probes raise Postgres `code`.
  #   * `concurrent: {note_id, bytes}`: a writer sets that body column just
  #     before the first heal window runs.
  defmodule FakeRepo do
    @moduledoc false
    @key {__MODULE__, :spec}

    def plan(spec) do
      :persistent_term.put(@key, spec)
      :persistent_term.put({__MODULE__, :calls}, :counters.new(2, []))
    end

    defdelegate query!(sql), to: Engram.Repo
    defdelegate query!(sql, params, opts), to: Engram.Repo
    defdelegate transaction(fun, opts), to: Engram.Repo

    def query!(sql, [user, after_id, size] = params) do
      spec = :persistent_term.get(@key)

      if String.contains?(sql, "UPDATE note_bodies") do
        n = bump(1)
        if n <= Keyword.get(spec, :lock_heal, 0), do: pg!(:lock_not_available)
        if n == 1, do: concurrent(spec[:concurrent])
        if too_slow?(spec, user, after_id, size), do: fail!(spec)
      end

      Engram.Repo.query!(sql, params)
    end

    def query!(sql, [_user] = params) do
      {times, code} = Keyword.get(:persistent_term.get(@key), :probe_fail, {0, nil})

      if String.starts_with?(String.trim(sql), "SELECT EXISTS") and bump(2) <= times,
        do: pg!(code)

      Engram.Repo.query!(sql, params)
    end

    def query!(sql, params), do: Engram.Repo.query!(sql, params)

    def calls(i), do: :counters.get(:persistent_term.get({__MODULE__, :calls}), i)

    # Counts calls of kind `i` (1 = heal window, 2 = probe).
    defp bump(i) do
      counters = :persistent_term.get({__MODULE__, :calls})
      :counters.add(counters, i, 1)
      :counters.get(counters, i)
    end

    defp concurrent(nil), do: :ok

    defp concurrent({note_id, bytes}) do
      Engram.Repo.query!("UPDATE note_bodies SET content_ct = $2 WHERE note_id = $1", [
        Ecto.UUID.dump!(note_id),
        bytes
      ])
    end

    defp too_slow?(spec, user, after_id, size) do
      if spec[:slow_over] && size > spec[:slow_over] do
        true
      else
        spec[:never] != nil and
          Engram.Repo.query!(
            "SELECT id FROM notes WHERE user_id = $1 AND id > $2 AND kind = 'note' ORDER BY id LIMIT 1",
            [user, after_id]
          ).rows == [[spec[:never]]]
      end
    end

    @pg_codes %{lock_not_available: "55P03", query_canceled: "57014"}

    defp pg!(code) do
      raise %Postgrex.Error{
        postgres: %{code: code, pg_code: @pg_codes[code], severity: "ERROR", message: "refused"}
      }
    end

    defp fail!(spec) do
      case Keyword.get(spec, :error, :timeout) do
        :timeout ->
          raise DBConnection.ConnectionError,
                "client #PID<0.1.0> timed out because it checked out the connection " <>
                  "for longer than 120000ms"

        :canceled ->
          pg!(:query_canceled)

        :closed ->
          raise DBConnection.ConnectionError, "tcp recv: closed"
      end
    end
  end

  defmodule HealMigration do
    @moduledoc false
    use Ecto.Migration
    @disable_ddl_transaction true
    @disable_migration_lock true

    def up do
      String.to_existing_atom("Elixir.Engram.Repo.Migrations.NoteBodiesPreNonceHealMigrate").heal(
        FakeRepo,
        :persistent_term.get({__MODULE__, :opts}, [])
      )
    end
  end

  defp pre_nonce!(u, v, n) do
    notes = for i <- 1..n, do: write!(u, v, "pre#{i}.md", "pre text #{i}")
    Enum.each(notes, &Engram.Fixtures.pre_nonce_null_body!(&1.id))
    notes
  end

  defp healed?(u, v, n), do: Enum.all?(1..n, &(read!(u, v, "pre#{&1}.md") == "pre text #{&1}"))

  # Runs the heal through the real migrator; returns its raise message.
  defp migrate_raise!(opts) do
    :persistent_term.put({HealMigration, :opts}, opts)
    version = 99_999_999_999_993

    error =
      assert_raise RuntimeError, fn ->
        Ecto.Migrator.up(Repo, version, HealMigration, log: false)
      end

    assert Repo.query!("SELECT count(*) FROM schema_migrations WHERE version = $1", [version]).rows ==
             [[0]]

    error.message
  end

  test "a window past its checkout deadline is halved down to one note", %{user: u, vault: v} do
    pre_nonce!(u, v, 3)
    FakeRepo.plan(slow_over: 1)

    assert :ok = heal!(FakeRepo, max_halvings: 10)
    assert healed?(u, v, 3)
  end

  test "a statement_timeout cancel (57014) is halved like the deadline", %{user: u, vault: v} do
    pre_nonce!(u, v, 3)
    FakeRepo.plan(slow_over: 1, error: :canceled)

    assert :ok = heal!(FakeRepo, max_halvings: 10)
    assert healed?(u, v, 3)
  end

  test "a dropped connection is not a slow window: it is raised", %{user: u, vault: v} do
    pre_nonce!(u, v, 3)
    FakeRepo.plan(slow_over: 1, error: :closed)

    assert_raise DBConnection.ConnectionError, ~r/closed/, fn -> heal!(FakeRepo) end
  end

  test "a note too slow even alone: the rest healed, count raised, migration not recorded", %{
    user: u,
    vault: v
  } do
    [stuck | _] = pre_nonce!(u, v, 3)
    FakeRepo.plan(slow_over: 1, never: Ecto.UUID.dump!(stuck.id))

    assert migrate_raise!(max_halvings: 10) =~ "1 note(s) too slow"
    assert read!(u, v, "pre1.md") == nil
    for i <- 2..3, do: assert(read!(u, v, "pre#{i}.md") == "pre text #{i}")
  end

  test "halving stops at its cap: the window's notes counted, raised", %{user: u, vault: v} do
    pre_nonce!(u, v, 3)
    FakeRepo.plan(slow_over: 1)

    assert migrate_raise!(max_halvings: 1) =~ "3 note(s) too slow"
  end

  test "past the boot deadline: the count raised, migration not recorded", %{
    user: u,
    vault: v
  } do
    pre_nonce!(u, v, 1)
    FakeRepo.plan([])

    assert migrate_raise!(deadline_ms: 0) =~ "1 user(s) not finished before the boot deadline"
  end

  test "a window that hits a lock timeout is retried", %{user: u, vault: v} do
    pre_nonce!(u, v, 2)
    FakeRepo.plan(lock_heal: 2)

    assert :ok = heal!(FakeRepo)
    assert healed?(u, v, 2)
  end

  test "a probe batch that hits a lock timeout is retried", %{user: u, vault: v} do
    pre_nonce!(u, v, 2)
    FakeRepo.plan(probe_fail: {1, :lock_not_available})

    assert :ok = heal!(FakeRepo)
    assert healed?(u, v, 2)
    # One refused probe, then the retry: a batch walked whole without it
    # would heal too, so the count is what proves the retry.
    assert FakeRepo.calls(2) == 2
  end

  test "a probe batch past its statement_timeout is walked anyway", %{user: u, vault: v} do
    pre_nonce!(u, v, 2)
    FakeRepo.plan(probe_fail: {1, :query_canceled})

    assert :ok = heal!(FakeRepo)
    assert healed?(u, v, 2)
  end

  # CONTROL: the body is set before the heal reads, so the window never
  # selects the note. The real race (a write between the heal's read and its
  # UPDATE) is `NoteBodiesPreNonceHealRaceTest`, on real connections.
  test "CONTROL: a body set before the heal is not selected", %{user: u, vault: v} do
    [raced | _] = pre_nonce!(u, v, 2)
    newer = <<1>> <> :crypto.strong_rand_bytes(60)
    FakeRepo.plan(concurrent: {raced.id, newer})

    assert :ok = heal!(FakeRepo)
    assert content_ct(raced) == [[newer]]
    assert read!(u, v, "pre2.md") == "pre text 2"
  end
end
