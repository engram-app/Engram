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

  setup_all do
    Code.require_file(
      "priv/repo/migrations/20261107130100_note_folder_hash_nullable_prep_expand.exs"
    )

    :ok
  end

  test "the checkout sets its own timeout, longer than the default" do
    mod =
      String.to_existing_atom("Elixir.Engram.Repo.Migrations.NoteFolderHashNullablePrepExpand")

    assert :ok = mod.with_lock_timeout(ShortDefaultRepo, ["SELECT pg_sleep(0.3)"])
  end
end
