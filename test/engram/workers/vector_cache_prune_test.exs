defmodule Engram.Workers.VectorCachePruneTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import ExUnit.CaptureLog
  import Engram.RlsCase

  alias Engram.Indexing.VectorCache
  alias Engram.Workers.VectorCachePrune

  @opts [model: "m", dims: 4, dtype: "float", input_type: "document"]

  setup do
    {:ok, user} = Engram.Fixtures.user_with_dek_fixture()
    {:ok, dek} = Engram.Crypto.get_dek(user)
    digest = VectorCache.digest("old", @opts)
    key = VectorCache.key_for_digest(:crypto.strong_rand_bytes(32), digest)
    :ok = VectorCache.put_many(user.id, nil, dek, [{key, digest, <<0::32, 0::32, 0::32, 0::32>>}])
    Repo.query!("UPDATE embedding_cache SET inserted_at = now() - interval '100 hours'")
    on_exit(fn -> Application.delete_env(:engram, :vector_cache_enabled) end)
    :ok
  end

  defp count, do: Repo.query!("SELECT count(*) FROM embedding_cache").rows |> hd() |> hd()

  test "flag off: a clean no-op, nothing deleted, nothing logged at error" do
    Application.put_env(:engram, :vector_cache_enabled, false)

    log = capture_log(fn -> assert :ok = perform_job(VectorCachePrune, %{}) end)

    assert count() == 1
    refute log =~ "[error]"
  end

  test "flag on: expires rows older than 72 h" do
    Application.put_env(:engram, :vector_cache_enabled, true)
    assert :ok = perform_job(VectorCachePrune, %{})
    assert count() == 0
  end

  test "flag on, RLS-enforcing role and no maintenance pool: :ok, never an error" do
    Application.put_env(:engram, :vector_cache_enabled, true)

    log =
      capture_log(fn ->
        assert {:returned, :ok} = as_prod_role(fn -> perform_job(VectorCachePrune, %{}) end)
      end)

    refute log =~ "[error]"
  end
end
