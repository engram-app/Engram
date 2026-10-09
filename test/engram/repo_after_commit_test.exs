defmodule Engram.RepoAfterCommitTest do
  use Engram.DataCase, async: true

  import ExUnit.CaptureLog

  alias Engram.Notes.Enqueue
  alias Engram.Repo

  test "after_commit runs after the outermost tenant transaction commits" do
    user = insert(:user)
    parent = self()

    {:ok, :done} =
      Repo.with_tenant(user.id, fn ->
        :ok = Repo.after_commit(fn -> send(parent, {:ran, Repo.in_transaction?()}) end)
        {:ok, :inner} = Repo.with_tenant(user.id, fn -> :inner end)
        refute_received {:ran, _}
        :done
      end)

    # In the SQL sandbox the outer with_tenant is a savepoint inside the test
    # transaction, so in_transaction? is true there; assert only ordering.
    assert_received {:ran, _}
  end

  test "after_commit callbacks dropped on rollback" do
    user = insert(:user)
    parent = self()

    assert_raise RuntimeError, fn ->
      Repo.with_tenant(user.id, fn ->
        :ok = Repo.after_commit(fn -> send(parent, :ran) end)
        raise "boom"
      end)
    end

    refute_received :ran

    # The queue does not leak into the next transaction.
    {:ok, :ok} = Repo.with_tenant(user.id, fn -> :ok end)
    refute_received :ran
  end

  test "after_commit callbacks dropped on Repo.rollback" do
    user = insert(:user)
    parent = self()

    {:error, :nope} =
      Repo.with_tenant(user.id, fn ->
        :ok = Repo.after_commit(fn -> send(parent, :ran) end)
        Repo.rollback(:nope)
      end)

    refute_received :ran
  end

  test "after_tenant runs inside the transaction with the tenant role reset" do
    user = insert(:user)
    parent = self()

    Repo.with_tenant(user.id, fn ->
      :ok =
        Repo.after_tenant(fn ->
          %{rows: [[role, tenant]]} =
            Repo.query!(
              "SELECT current_setting('role'), current_setting('app.current_tenant', true)"
            )

          send(parent, {:after_tenant, role, tenant})
        end)
    end)

    assert_received {:after_tenant, "none", ""}
  end

  test "outside a transaction both hooks run immediately" do
    parent = self()
    :ok = Repo.after_commit(fn -> send(parent, :now) end)
    assert_received :now
    :ok = Repo.after_tenant(fn -> send(parent, :tenant_now) end)
    assert_received :tenant_now
  end

  test "a raising after_commit callback is logged, the rest still run, the result stands" do
    user = insert(:user)
    parent = self()

    log =
      capture_log(fn ->
        assert {:ok, :done} =
                 Repo.with_tenant(user.id, fn ->
                   :ok = Repo.after_commit(fn -> raise "post-commit boom" end)
                   :ok = Repo.after_commit(fn -> send(parent, :second) end)
                   :done
                 end)
      end)

    assert_received :second
    assert log =~ "after_commit callback failed"
  end

  test "a callback can open its own tenant transaction" do
    user = insert(:user)
    parent = self()

    Repo.with_tenant(user.id, fn ->
      Repo.after_commit(fn ->
        {:ok, tenant} =
          Repo.with_tenant(user.id, fn ->
            %{rows: [[t]]} = Repo.query!("SELECT current_setting('app.current_tenant', true)")
            t
          end)

        send(parent, {:tenant, tenant})
      end)
    end)

    expected = user.id
    assert_received {:tenant, ^expected}
  end

  test "a cache eviction inside an outer tenant transaction happens after commit" do
    user = insert(:user)
    Engram.Cache.put(:test_cache_forever, user.id, :stale)

    Repo.with_tenant(user.id, fn ->
      :ok = Engram.Cache.evict(:test_cache_forever, user.id)
      # Another process reloading here would read the pre-commit row and
      # re-cache it, so the entry must survive until commit.
      assert Engram.Cache.get(:test_cache_forever, user.id) == {:ok, :stale}
    end)

    assert Engram.Cache.get(:test_cache_forever, user.id) == :miss
  end

  test "Enqueue.enqueue inside a tenant transaction inserts after the role reset" do
    user = insert(:user)
    parent = self()

    insert_fn = fn _cs ->
      %{rows: [[role]]} = Repo.query!("SELECT current_setting('role')")
      send(parent, {:inserted, role})
      {:ok, :job}
    end

    Repo.with_tenant(user.id, fn ->
      assert {:ok, _} = Enqueue.enqueue(:changeset, "test_worker", insert_fn)
      refute_received {:inserted, _}
    end)

    assert_received {:inserted, "none"}
  end

  test "Sync.Broadcast.emit inside a tenant transaction fires after commit, not on rollback" do
    user = insert(:user)
    topic = "sync:#{user.id}:after-commit-test"
    :ok = Phoenix.PubSub.subscribe(Engram.PubSub, topic)

    Repo.with_tenant(user.id, fn ->
      :ok = Engram.Sync.Broadcast.emit(topic, "note_changed", %{"id" => "a"})
      refute_received %Phoenix.Socket.Broadcast{}
    end)

    assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: %{"id" => "a"}}

    assert_raise RuntimeError, fn ->
      Repo.with_tenant(user.id, fn ->
        :ok = Engram.Sync.Broadcast.emit(topic, "note_changed", %{"id" => "b"})
        raise "boom"
      end)
    end

    refute_receive %Phoenix.Socket.Broadcast{payload: %{"id" => "b"}}, 50
  end
end
