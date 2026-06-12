defmodule Engram.CacheTest do
  use ExUnit.Case, async: false
  alias Engram.Cache
  alias Engram.Cache.Redix, as: CacheRedix

  # Returns a Redix-style {:error, _} carrying a URL-bearing tuple, so we can
  # prove the bounded reason classifier never forwards the raw (secret-bearing)
  # term into telemetry metadata.
  defmodule LeakyErroringRedix do
    @leak "redis://user:SUPERSECRET@cache:6379"
    def leak, do: @leak
    def command(_cmd), do: {:error, {:auth_failed, @leak}}
  end

  # Raises with the secret in the message — exercises the rescue path; only the
  # exception module (not the message) may reach telemetry.
  defmodule LeakyRaisingRedix do
    @leak "redis://user:SUPERSECRET@cache:6379"
    def leak, do: @leak
    def command(_cmd), do: raise("connection failed for #{@leak}")
  end

  setup do
    start_supervised!(Engram.Cache.FakeRedix)
    on_exit(fn -> Application.delete_env(:engram, Cache) end)
    :ok
  end

  test "default backend is :ets" do
    Application.delete_env(:engram, Cache)
    assert Cache.backend() == :ets
  end

  test "backend/0 reflects configured :redis" do
    Application.put_env(:engram, Cache, backend: :redis)
    assert Cache.backend() == :redis
  end

  describe "redis ops via injected impl" do
    setup do
      Application.put_env(:engram, Cache, backend: :redis, redis_impl: Engram.Cache.FakeRedix)
      :ok
    end

    test "set then get round-trips" do
      assert Cache.redis_set(:activity, "k", "v", 60) == :ok
      assert Cache.redis_get(:activity, "k") == {:ok, "v"}
    end

    test "set sends the exact key and EX <ttl> on the wire" do
      assert Cache.redis_set(:terms, "terms:42:terms_of_service", "2026-05-19", 86_400) == :ok

      assert ["SET", "terms:42:terms_of_service", "2026-05-19", "EX", "86400"] in Engram.Cache.FakeRedix.commands()
    end

    test "missing key returns :miss" do
      assert Cache.redis_get(:activity, "absent") == :miss
    end
  end

  describe "fail-open" do
    test "redis_get on a dead connection returns :miss + telemetry tagged cache/op (catch :exit)" do
      # Default impl Engram.Cache.Redix, but no connection process is started.
      Application.put_env(:engram, Cache, backend: :redis)
      attach()
      assert Cache.redis_get(:activity, "k") == :miss
      assert_receive {:cache_degraded, %{count: 1}, %{cache: :activity, op: :get, reason: reason}}
      assert is_atom(reason)
    end

    test "redis_set on a dead connection returns :ok + telemetry tagged cache/op" do
      Application.put_env(:engram, Cache, backend: :redis)
      attach()
      assert Cache.redis_set(:terms, "k", "v", 60) == :ok
      assert_receive {:cache_degraded, %{count: 1}, %{cache: :terms, op: :set, reason: reason}}
      assert is_atom(reason)
    end

    test "an {:error, {atom, secret}} reply is bounded to the outer atom — no leak" do
      Application.put_env(:engram, Cache, backend: :redis, redis_impl: LeakyErroringRedix)
      attach()
      assert Cache.redis_get(:activity, "k") == :miss
      assert_receive {:cache_degraded, %{count: 1}, %{reason: reason}}
      assert reason == :auth_failed
      # The URL/password must never reach telemetry metadata.
      refute inspect(reason) =~ "SUPERSECRET"
      refute inspect(reason) =~ LeakyErroringRedix.leak()
    end

    test "a raise carrying the secret is bounded to the exception module — no leak" do
      Application.put_env(:engram, Cache, backend: :redis, redis_impl: LeakyRaisingRedix)
      attach()
      assert Cache.redis_get(:activity, "k") == :miss
      assert_receive {:cache_degraded, %{count: 1}, %{reason: reason}}
      assert reason == RuntimeError
      refute inspect(reason) =~ "SUPERSECRET"
    end
  end

  describe "Engram.Cache.Redix child_spec" do
    test "starts a pool of connections, no :socket_opts for plain-tcp redis:// URLs" do
      # One Redix connection was a per-node serialization point: every
      # cache round trip funneled through a single process + socket, and
      # under load the 250ms timeout flipped the façade to fail-open.
      # `customize_hostname_check` is `:ssl`-only — MUST stay omitted on
      # plain-tcp (gen_tcp rejects it → boot-loop).
      spec = CacheRedix.child_spec(url: "redis://localhost:6379")
      assert spec.type == :supervisor
      assert {Supervisor, :start_link, [children, [strategy: :one_for_one]]} = spec.start
      assert length(children) == 8

      names =
        for %{start: {Redix, :start_link, [_url, opts]}} <- children do
          assert opts[:sync_connect] == false
          refute Keyword.has_key?(opts, :socket_opts)
          opts[:name]
        end

      assert names == CacheRedix.pool_conn_names()
    end

    test "appends the :https-shape hostname match_fun to EVERY pooled conn for rediss://" do
      # AWS ElastiCache/Valkey wildcard certs (`*.cluster.cache.amazonaws.com`)
      # fail Erlang's default strict literal hostname check on leftmost-label
      # hosts. The `:https`-shape match_fun applies RFC 6125 wildcard rules.
      spec = CacheRedix.child_spec(url: "rediss://master.example:6379")
      assert {Supervisor, :start_link, [children, _opts]} = spec.start
      assert length(children) == 8

      for %{start: {Redix, :start_link, [_url, opts]}} <- children do
        assert [customize_hostname_check: [match_fun: match_fun]] = opts[:socket_opts]
        assert is_function(match_fun)
      end
    end

    test "command routing spreads callers across the pool deterministically" do
      parent = self()

      for _ <- 1..200 do
        spawn(fn -> send(parent, {:conn, CacheRedix.pool_conn_name()}) end)
      end

      names =
        for _ <- 1..200 do
          receive do
            {:conn, n} -> n
          after
            1_000 -> flunk("missing conn name message")
          end
        end

      valid = MapSet.new(CacheRedix.pool_conn_names())
      assert Enum.all?(names, &MapSet.member?(valid, &1))
      # Same pid always maps to the same conn; distinct pids spread out.
      assert names |> Enum.uniq() |> length() > 1
      assert CacheRedix.pool_conn_name() == CacheRedix.pool_conn_name()
    end
  end

  defp attach do
    ref = make_ref()
    name = "cache-degraded-#{inspect(ref)}"

    :telemetry.attach(
      name,
      [:engram, :cache, :backend_error],
      fn _event, meas, meta, pid -> send(pid, {:cache_degraded, meas, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(name) end)
  end
end
