defmodule Engram.Migrations.NoteFolderHashPrepTimeoutTest do
  @moduledoc """
  The pinned connection has to outlive a full-table `VALIDATE CONSTRAINT`.

  With no `timeout:` the `checkout` inherits DBConnection's 15s, which covers
  every statement inside it. Nothing in a test takes 15s, so `ShortDefaultRepo`
  stands in a 50ms default and the statement takes longer: a checkout that sets
  no timeout of its own dies on the real deadline.
  """
  use Engram.DataCase, async: false

  defmodule ShortDefaultRepo do
    @moduledoc false
    def checkout(fun, opts \\ []) do
      Engram.Repo.checkout(fun, Keyword.put_new(opts, :timeout, 50))
    end

    defdelegate query!(sql), to: Engram.Repo
    defdelegate query!(sql, params, opts), to: Engram.Repo
  end

  # Refuses the first statement it is given with a lock timeout, `:times` times.
  defmodule LockedRepo do
    @moduledoc false
    def checkout(fun, opts), do: Engram.Repo.checkout(fun, opts)
    defdelegate query!(sql), to: Engram.Repo

    def query!(sql, params, opts) do
      left = :persistent_term.get({__MODULE__, :left})

      if left > 0 do
        :persistent_term.put({__MODULE__, :left}, left - 1)

        raise %Postgrex.Error{
          postgres: %{
            code: :lock_not_available,
            pg_code: "55P03",
            severity: "ERROR",
            message: "lock timeout"
          }
        }
      end

      Engram.Repo.query!(sql, params, opts)
    end
  end

  setup_all do
    Code.require_file(
      "priv/repo/migrations/20261107130100_note_folder_hash_nullable_prep_expand.exs"
    )

    Code.require_file(
      "priv/repo/migrations/20261107130000_note_folder_hash_drop_not_null_expand.exs"
    )

    :ok
  end

  test "DROP NOT NULL that hits its lock timeout is retried, then gives up" do
    mod = String.to_existing_atom("Elixir.Engram.Repo.Migrations.NoteFolderHashDropNotNullExpand")

    :persistent_term.put({LockedRepo, :left}, 2)
    assert :ok = mod.drop_not_null(LockedRepo)

    :persistent_term.put({LockedRepo, :left}, 3)
    assert_raise Postgrex.Error, fn -> mod.drop_not_null(LockedRepo) end
  end

  test "the checkout sets its own timeout, longer than the default" do
    mod =
      String.to_existing_atom("Elixir.Engram.Repo.Migrations.NoteFolderHashNullablePrepExpand")

    assert :ok = mod.with_lock_timeout(ShortDefaultRepo, ["SELECT pg_sleep(0.3)"])
  end

  test "a statement that hits its lock timeout is retried, then gives up" do
    mod =
      String.to_existing_atom("Elixir.Engram.Repo.Migrations.NoteFolderHashNullablePrepExpand")

    :persistent_term.put({LockedRepo, :left}, 2)
    assert :ok = mod.with_lock_timeout(LockedRepo, ["SELECT 1"])

    :persistent_term.put({LockedRepo, :left}, 3)
    assert_raise Postgrex.Error, fn -> mod.with_lock_timeout(LockedRepo, ["SELECT 1"]) end
  end
end
