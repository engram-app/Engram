defmodule Engram.Indexing.VectorCacheRlsTest do
  @moduledoc """
  `embedding_cache` under an ENFORCED policy (`engram_app`, no tenant set),
  per docs/context/rls-enforcement-testing-traps.md. Every VectorCache write
  and read gets its own test: one scoped statement proves nothing about the
  next (trap 2). The CONTROL shows the role drop engages at all.
  """
  use Engram.DataCase, async: false

  import Engram.RlsCase

  alias Engram.Crypto
  alias Engram.Indexing.VectorCache
  alias Engram.Repo

  @opts [model: "m", dims: 4, dtype: "float", input_type: "document"]
  @vec <<0.5::float-32-little, -0.25::float-32-little, 0.0::float-32-little,
         1.0::float-32-little>>

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, ck} = Crypto.dek_content_hash_key(user)
    digest = VectorCache.digest("secret text", @opts)
    key = VectorCache.key_for_digest(ck, digest)
    %{user: user, dek: dek, ck: ck, digest: digest, key: key}
  end

  defp count_rows,
    do: Repo.query!("SELECT count(*) FROM embedding_cache").rows |> hd() |> hd()

  defp seed(%{user: user, dek: dek, key: key, digest: digest}) do
    :ok = VectorCache.put_many(user.id, nil, dek, [{key, digest, @vec}])
    # Precondition, not decoration: the superuser sees the row.
    assert count_rows() == 1
  end

  test "CONTROL: engram_app with no tenant set sees zero rows", ctx do
    seed(ctx)
    assert {:returned, 0} = as_prod_role(&count_rows/0)
  end

  test "put_many writes under the owner's tenant (an unscoped INSERT raises 42501)", ctx do
    %{user: user, dek: dek, key: key, digest: digest} = ctx

    assert {:returned, 1} =
             as_prod_role(fn ->
               :ok = VectorCache.put_many(user.id, nil, dek, [{key, digest, @vec}])
               # Read back as the superuser view would: the row exists.
               Repo.with_tenant!(user.id, &count_rows/0)
             end)
  end

  test "get_many reads the owner's row (unscoped it would be filtered to a miss)", ctx do
    seed(ctx)
    %{user: user, dek: dek, key: key} = ctx

    assert {:returned, %{^key => @vec}} =
             as_prod_role(fn -> VectorCache.get_many(user.id, dek, [key]) end)
  end

  test "another user's lookup with the owner's key gets nothing", ctx do
    seed(ctx)
    {:ok, other} = Engram.Fixtures.user_with_dek_fixture()
    %{dek: dek, key: key} = ctx

    assert {:returned, hits} = as_prod_role(fn -> VectorCache.get_many(other.id, dek, [key]) end)
    assert hits == %{}
  end

  test "rotate re-keys the owner's rows (persisted effect, committed)", ctx do
    seed(ctx)
    %{user: user, dek: dek, key: old_key} = ctx
    new_dek = :crypto.strong_rand_bytes(32)

    :ok = as_prod_role_committing(fn -> VectorCache.rotate(user.id, dek, new_dek) end)

    new_key =
      VectorCache.key(Crypto.dek_content_hash_key_from_bytes(new_dek), "secret text", @opts)

    assert [[^new_key]] =
             Repo.query!("SELECT key FROM embedding_cache WHERE user_id = $1", [
               Ecto.UUID.dump!(user.id)
             ]).rows

    refute new_key == old_key
  end
end
