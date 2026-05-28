defmodule Engram.ClusterCase do
  @moduledoc """
  Spins up a single extra BEAM node via `:peer` for cross-node PubSub tests.
  Deliberately minimal and DB-free: it starts only `Phoenix.PubSub` (name
  `Engram.PubSub`) and the cache GenServers under test on the peer, then
  connects the two nodes so PubSub's pg-based adapter fans out across them.
  Avoiding `Application.ensure_all_started(:engram)` (and thus the Ecto
  sandbox) is what keeps this deterministic.
  """

  @doc """
  Start a peer node, make this node distributed if needed, share the code paths,
  start PubSub + the given child modules on the peer, and connect. Returns
  `{peer_pid, peer_node}`. The peer is torn down on test exit via `on_exit`.

  ## Why :peer.start instead of :peer.start_link

  ExUnit on_exit callbacks run in a separate process AFTER the test process has
  exited. With start_link the peer control process would be linked to the test
  process; when the test process exits normally, the peer control process dies
  too, making the on_exit :peer.stop/1 call crash with EXIT/shutdown on an
  already-dead pid. Using :peer.start avoids that link so the on_exit remains
  the sole point of teardown.
  """
  def start_peer!(children, on_exit_fun) do
    unless Node.alive?() do
      {:ok, _} = :net_kernel.start([:"primary@127.0.0.1", :longnames])
      Node.set_cookie(:engram_cluster_test)
    end

    {:ok, peer_pid, peer_node} =
      :peer.start(%{
        name: peer_name(),
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io
      })

    on_exit_fun.(fn -> :peer.stop(peer_pid) end)

    true = :peer.call(peer_pid, :erlang, :set_cookie, [Node.get_cookie()])

    for path <- :code.get_path() do
      :peer.call(peer_pid, :code, :add_pathz, [path])
    end

    # ensure_all_started routes through the app controller, which is persistent,
    # so its children (the :pg scope used by Phoenix.PubSub.PG2) outlive this call.
    {:ok, _} = :peer.call(peer_pid, Application, :ensure_all_started, [:phoenix_pubsub])

    # Calling start_link directly via :peer.call would link the started process to
    # the ephemeral erpc handler, which exits when the call returns, killing the
    # child. Instead we start a permanent holder process on the peer (via spawn/1,
    # which does NOT link to the caller). The holder starts a supervisor as its
    # child (so the supervisor is linked to the holder, not the erpc handler),
    # then waits. We synchronise via a one-shot message so the caller blocks until
    # all children are up before returning.
    origin = self()

    :peer.call(peer_pid, :erlang, :apply, [
      fn ->
        child_specs =
          [{Phoenix.PubSub.Supervisor, [name: Engram.PubSub]}] ++
            Enum.map(children, fn m -> {m, []} end)

        spawn(fn ->
          {:ok, _sup} = Supervisor.start_link(child_specs, strategy: :one_for_one)
          send(origin, :peer_sup_ready)
          Process.sleep(:infinity)
        end)
      end,
      []
    ])

    receive do
      :peer_sup_ready -> :ok
    after
      5_000 -> raise "Timeout waiting for peer supervisor to start"
    end

    true = :peer.call(peer_pid, Node, :connect, [Node.self()])
    {peer_pid, peer_node}
  end

  # Fixed, compile-time node name (not an interpolated/dynamic atom — Credo's
  # Warning.UnsafeToAtom is enforced in test/ too). Safe to reuse: the only
  # peer user is the `async: false` cluster test, and `on_exit` stops the peer
  # (freeing the epmd name) before any subsequent test runs.
  defp peer_name, do: :engram_cluster_test_peer
end
