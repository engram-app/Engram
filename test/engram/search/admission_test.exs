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

  describe "pool_busy/2" do
    test "a real Finch pool checkout timeout becomes busy and is logged with its upstream" do
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/", fn conn ->
        Process.sleep(300)
        Plug.Conn.send_resp(conn, 200, "ok")
      end)

      finch = __MODULE__.Finch
      start_supervised!({Finch, name: finch, pools: %{default: [size: 1, count: 1]}})
      url = "http://localhost:#{bypass.port}/"
      request = fn -> Req.get(url, finch: [name: finch, pool_timeout: 20], retry: false) end

      busy = Task.async(request)
      Process.sleep(50)

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
          raise RuntimeError,
                "Finch was unable to provide a connection within the timeout due to " <>
                  "excess queuing for connections."

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

    test "a pool checkout timeout in the query embed is busy, not a raise or a keyword degrade",
         %{users: [{a, a_vault} | _]} do
      {adm, q} = gates()

      log =
        capture_log([level: :warning], fn ->
          assert Search.search(a, a_vault, "pool") == {:error, :search_busy}
          assert Search.search(a, a_vault, "pool", mode: :vector) == {:error, :search_busy}
        end)

      assert log =~ "query_embed"
      refute log =~ "degraded to keyword-only"
      assert counts(adm) == %{}
      assert counts(q) == %{}
    end
  end
end
