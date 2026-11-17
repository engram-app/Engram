defmodule Engram.Search.AdmissionTest do
  @moduledoc """
  Per-user admission of WHOLE searches (`Engram.Search.Gate.admit/2`): embed
  plus every Qdrant call, outside the per-request Qdrant slot. And a Finch
  pool checkout timeout on the search path is a busy refusal, never a 500.
  Every test runs on its own unregistered gates.
  """
  use Engram.DataCase, async: true

  import Engram.Factory
  import ExUnit.CaptureLog

  alias Engram.Search
  alias Engram.Search.Gate
  alias Engram.ServiceConfig

  @wait 150
  @pool_msg "Finch was unable to provide a connection within the timeout due to " <>
              "excess queuing for connections."

  # Per-test admission and Qdrant gates, this process's searches pointed at both.
  defp gates(admission \\ [], qdrant \\ []) do
    a =
      start_gate(
        Keyword.merge(
          [
            kind: :admission,
            admission_limit: 8,
            admission_per_user: 1,
            admission_max_waiting: 16,
            admission_max_waiting_per_user: 1
          ],
          admission
        )
      )

    q =
      start_gate(
        Keyword.merge([limit: 4, per_user: 2, max_waiting: 32, max_waiting_per_user: 8], qdrant)
      )

    ServiceConfig.put_override(:search_gate,
      gate: q,
      admission_gate: a,
      acquire_timeout: @wait
    )

    {a, q}
  end

  defp start_gate(opts),
    do:
      start_supervised!(%{
        id: make_ref(),
        start: {Gate, :start_link, [Keyword.put(opts, :name, nil)]}
      })

  # Holds an admission for `user` until sent `:go` (or killed).
  defp admitted(user) do
    test = self()

    {:ok, pid} =
      Task.start(fn ->
        Gate.admit(user, fn ->
          send(test, {:admitted, self()})
          receive do: (:go -> :ok)
        end)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:admitted, ^pid}, 2_000
    pid
  end

  defp counts(g), do: :sys.get_state(g).counts

  # Polls the gate until its per-user queue matches, failing after 2 s.
  defp wait_queued(g, queued, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      :sys.get_state(g).queued == queued ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("queue never reached #{inspect(queued)}")

      true ->
        receive(after: (1 -> wait_queued(g, queued, deadline)))
    end
  end

  describe "admit/2" do
    test "a user over the admission limit is busy while another user is not" do
      gates()
      holder = admitted("a")

      assert Gate.admit("a", fn -> :ran end) == {:error, :search_busy}
      assert Gate.admit("b", fn -> :ran end) == :ran

      send(holder, :go)
    end

    test "zero waiting room refuses at once, not after the acquire timeout" do
      gates(admission_max_waiting_per_user: 0)
      holder = admitted("a")

      {us, result} = :timer.tc(fn -> Gate.admit("a", fn -> :ran end) end)
      assert result == {:error, :search_busy}
      assert us < @wait * 1_000

      send(holder, :go)
    end

    test "a waiting admission runs when its user's slot frees" do
      {a, q} = gates()
      ServiceConfig.put_override(:search_gate, gate: q, admission_gate: a, acquire_timeout: 5_000)
      holder = admitted("a")

      waiter = Task.async(fn -> Gate.admit("a", fn -> :second end) end)
      wait_queued(a, %{"a" => 1})
      send(holder, :go)
      assert Task.await(waiter, 2_000) == :second
    end

    test "is released on success, on an error result, on a raise and on a throw" do
      {a, _q} = gates()

      assert Gate.admit("a", fn -> :ok end) == :ok
      assert Gate.admit("a", fn -> {:error, :boom} end) == {:error, :boom}
      assert_raise RuntimeError, "boom", fn -> Gate.admit("a", fn -> raise "boom" end) end
      assert catch_throw(Gate.admit("a", fn -> throw(:t) end)) == :t

      assert counts(a) == %{}
      assert Gate.admit("a", fn -> :again end) == :again
    end

    test "is released when the admitted caller is killed" do
      {a, _q} = gates()
      holder = admitted("a")
      assert counts(a) == %{"a" => 1}

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, :killed}

      assert Gate.admit("a", fn -> :ran end) == :ran
      assert counts(a) == %{}
    end

    test "nests the per-request Qdrant slot without tripping the double-acquire raise" do
      {a, q} = gates()

      assert Gate.admit("a", fn ->
               Gate.run("a", fn -> {counts(a), counts(q)} end)
             end) == {%{"a" => 1}, %{"a" => 1}}

      assert counts(a) == %{}
      assert counts(q) == %{}
    end

    test "fails closed when the admission gate is down" do
      gates()
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, _, _, _}
      ServiceConfig.put_override(:search_gate, admission_gate: dead, acquire_timeout: @wait)

      assert Gate.admit("a", fn -> :ran end) == {:error, :search_busy}
    end
  end

  describe "telemetry" do
    setup do
      handler = "admission-#{inspect(self())}"
      test = self()

      :telemetry.attach(
        handler,
        [:engram, :search, :gate],
        fn _e, m, meta, pid -> if self() == pid, do: send(pid, {:gate_event, m, meta}) end,
        test
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "an admission refusal emits the gate event tagged with its gate" do
      gates(admission_max_waiting_per_user: 0)
      holder = admitted("a")

      assert Gate.admit("a", fn -> :ran end) == {:error, :search_busy}

      assert_receive {:gate_event, %{wait: w},
                      %{outcome: :busy, gate: :admission, upstream: :none}}

      assert is_integer(w)
      send(holder, :go)
    end

    test "an admission and a Qdrant slot each emit ok with their gate" do
      gates()
      assert Gate.admit("a", fn -> Gate.run("a", fn -> :ran end) end) == :ran
      assert_receive {:gate_event, _, %{outcome: :ok, gate: :admission, upstream: :none}}
      assert_receive {:gate_event, _, %{outcome: :ok, gate: :qdrant, upstream: :none}}
    end

    test "a pool-busy refusal emits busy tagged :pool with its upstream" do
      assert Gate.pool_busy(:query_embed, fn -> raise RuntimeError, @pool_msg end) ==
               {:error, :search_busy}

      assert_receive {:gate_event, _, %{outcome: :busy, gate: :pool, upstream: :query_embed}}
    end
  end

  describe "pool_busy/2" do
    test "a real Finch pool checkout timeout becomes busy and is logged with its upstream" do
      bypass = Bypass.open()

      test = self()

      Bypass.stub(bypass, "GET", "/", fn conn ->
        send(test, :in_handler)
        Process.sleep(300)
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      finch = __MODULE__.Finch
      start_supervised!({Finch, name: finch, pools: %{default: [size: 1, count: 1]}})
      url = "http://localhost:#{bypass.port}/"
      request = fn -> Req.get(url, finch: [name: finch, pool_timeout: 20], retry: false) end

      # The first request holds the pool's one connection once its handler runs.
      busy = Task.async(request)
      assert_receive :in_handler, 2_000

      log =
        capture_log([level: :warning], fn ->
          assert Gate.pool_busy(:qdrant, request) == {:error, :search_busy}
        end)

      assert log =~ "connection pool"
      assert log =~ "qdrant"
      assert {:ok, %{status: 200}} = Task.await(busy, 2_000)
    end

    test "any other RuntimeError still raises" do
      assert_raise RuntimeError, "something else", fn ->
        Gate.pool_busy(:voyage, fn -> raise "something else" end)
      end
    end

    test "passes results through untouched" do
      assert Gate.pool_busy(:voyage, fn -> {:error, :timeout} end) == {:error, :timeout}
      assert Gate.pool_busy(:voyage, fn -> {:ok, 1} end) == {:ok, 1}
    end
  end

  describe "through Engram.Search" do
    setup do
      bypass = Bypass.open()
      ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
      ServiceConfig.put_override(:qdrant_search_timeout, 30_000)

      json = fn conn, body ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end

      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/query/batch", fn conn ->
        json.(conn, ~s({"result":[{"points":[]},{"points":[]}]}))
      end)

      Bypass.stub(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
        json.(conn, ~s({"result":{"points":[]}}))
      end)

      test = self()

      Mox.stub(Engram.MockEmbedder, :embed_texts, fn
        ["hold"], _opts ->
          send(test, {:embedding, self()})
          receive do: (:go -> {:ok, [[0.1, 0.2, 0.3]]})

        ["pool"], _opts ->
          raise RuntimeError, @pool_msg

        texts, _opts ->
          {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      users =
        for _ <- 1..2 do
          {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
          {user, insert(:vault, user: user)}
        end

      %{users: users}
    end

    test "the whole search, embed included, counts against admission",
         %{users: [{a, a_vault}, {b, b_vault}]} do
      {adm, _q} = gates()
      slow = Task.async(fn -> Search.search(a, a_vault, "hold") end)
      assert_receive {:embedding, embedder}, 2_000

      # A is inside its embed, holding no Qdrant slot, but its admission.
      assert Search.search(a, a_vault, "second") == {:error, :search_busy}
      assert Search.similar(a, a_vault, [Ecto.UUID.generate()]) == {:error, :search_busy}
      assert Search.search(b, b_vault, "other user") == {:ok, []}

      send(embedder, :go)
      assert Task.await(slow, 5_000) == {:ok, []}
      assert counts(adm) == %{}
    end

    test "a pool checkout timeout in a vector-only query embed is busy, not a raise",
         %{users: [{a, a_vault} | _]} do
      {adm, q} = gates()

      log =
        capture_log([level: :warning], fn ->
          assert Search.search(a, a_vault, "pool", mode: :vector) == {:error, :search_busy}
        end)

      assert log =~ "query_embed"
      assert counts(adm) == %{}
      assert counts(q) == %{}
    end

    test "a pool checkout timeout in a hybrid query embed degrades to keyword-only",
         %{users: [{a, a_vault} | _]} do
      gates()

      log =
        capture_log([level: :warning], fn ->
          assert Search.search(a, a_vault, "pool") == {:ok, []}
        end)

      assert log =~ "degraded to keyword-only"
    end

    test "a busy search costs no daily search token", %{users: [{a, a_vault} | _]} do
      gates()
      insert(:user_limit_override, user: a, key: "ai_searches_per_day", value: %{"v" => 1})

      capture_log(fn ->
        assert Search.search(a, a_vault, "pool", mode: :vector) == {:error, :search_busy}
      end)

      # The one token is still there: this search runs, the next is capped.
      assert Search.search(a, a_vault, "served") == {:ok, []}
      assert {:error, :search_cap_exceeded, 1} = Search.search(a, a_vault, "capped")
    end
  end
end
