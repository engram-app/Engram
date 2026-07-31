defmodule Engram.Cluster.ReadinessTest do
  use ExUnit.Case, async: true

  alias Engram.Cluster.Readiness

  describe "decide/1 (pure gate decision)" do
    test "ready when any peer is connected" do
      assert :ready =
               Readiness.decide(%{
                 peers: [:"engram@10.0.0.2"],
                 other_ips: ["10.0.0.2"],
                 uptime_ms: 0,
                 grace_ms: 60_000
               })
    end

    test "legitimately alone when discovery shows no other node (first task, scale-to-1, DR)" do
      assert {:ready, :alone} =
               Readiness.decide(%{peers: [], other_ips: [], uptime_ms: 0, grace_ms: 60_000})
    end

    test "waiting when peers exist in DNS but none are connected and grace has not elapsed" do
      assert :waiting =
               Readiness.decide(%{
                 peers: [],
                 other_ips: ["10.0.0.9"],
                 uptime_ms: 10_000,
                 grace_ms: 60_000
               })
    end

    test "passes with grace_expired once the boot grace elapses, so a broken discovery layer cannot wedge a deploy" do
      assert {:ready, :grace_expired} =
               Readiness.decide(%{
                 peers: [],
                 other_ips: ["10.0.0.9"],
                 uptime_ms: 60_000,
                 grace_ms: 60_000
               })
    end
  end

  describe "check/1" do
    test "not_clustered when no DNS cluster query is configured (self-host, dev, test)" do
      assert :not_clustered = Readiness.check(query: nil)
    end

    test "ready when clustered and peers are connected" do
      assert :ready =
               Readiness.check(
                 query: "app.engram.internal",
                 peers: fn -> [:"engram@10.0.0.2"] end,
                 resolver: fn _ -> ["10.0.0.2", "10.0.0.3"] end
               )
    end

    test "excludes own IP from discovered peers (a node that only sees itself is alone)" do
      # node() is :nonode@nohost in tests; inject self_ip to simulate a
      # distributed node whose Cloud Map record is the only one.
      assert {:ready, :alone} =
               Readiness.check(
                 query: "app.engram.internal",
                 peers: fn -> [] end,
                 resolver: fn _ -> ["10.0.0.7"] end,
                 self_ip: "10.0.0.7"
               )
    end

    test "waiting while other nodes are discoverable but unjoined, within grace" do
      assert :waiting =
               Readiness.check(
                 query: "app.engram.internal",
                 peers: fn -> [] end,
                 resolver: fn _ -> ["10.0.0.9"] end,
                 self_ip: "10.0.0.7",
                 uptime_ms: 1_000,
                 grace_ms: 60_000
               )
    end

    test "grace_expired for a node that never joined (incl. undistributed node — the Jul 3 class)" do
      assert {:ready, :grace_expired} =
               Readiness.check(
                 query: "app.engram.internal",
                 peers: fn -> [] end,
                 resolver: fn _ -> ["10.0.0.9"] end,
                 self_ip: "10.0.0.7",
                 uptime_ms: 120_000,
                 grace_ms: 60_000
               )
    end

    test "fails open to alone when DNS resolution errors (empty lookup) — a Cloud Map outage cannot block boot" do
      assert {:ready, :alone} =
               Readiness.check(
                 query: "app.engram.internal",
                 peers: fn -> [] end,
                 resolver: fn _ -> [] end
               )
    end

    test "steady state (peer already joined) never calls the resolver — must stay out of the hot path" do
      assert :ready =
               Readiness.check(
                 query: "app.engram.internal",
                 peers: fn -> [:"engram@10.0.0.2"] end,
                 resolver: fn _ ->
                   raise "resolver must not be invoked when peers are already connected"
                 end
               )
    end
  end

  describe "resolve_a/2 (real :inet_res call, bounded timeout)" do
    # The invariant that actually matters — "we did not ship an unbounded
    # resolver, so a hung VPC/Cloud Map lookup cannot pull every task out of
    # rotation" — is arithmetic, so assert it as arithmetic. No clock, cannot
    # flake, and it fails the moment someone raises @resolve_timeout_ms.
    #
    # This also closes a real gap: the timing test below hard-codes its own
    # threshold, so raising the production timeout could have blown the ALB
    # health-check budget while the test carried on passing.
    test "the shipped resolver budget stays well under the 5s ALB health-check timeout" do
      assert Readiness.resolve_budget_ms() <= 2_000,
             "resolve_a's worst case is #{Readiness.resolve_budget_ms()}ms; the ALB health " <>
               "check times out at 5s, so a bound this large risks pulling healthy tasks " <>
               "out of rotation"
    end

    # And prove the bound is honoured, with a SMALL window.
    #
    # This used to run the production 1_500ms timeout and assert < 4s. Nominal
    # is 1.50s (measured), so ~2.7x headroom, which sounds ample but it is wall
    # clock around a real network call inside a parallel suite: on a loaded
    # machine it recorded 4.08s and 5.50s and went red twice (#1158).
    #
    # 300ms nominal against a 2s assertion is ~6.6x headroom for identical
    # coverage. :inet_res rejects retry: 0, so shrinking `timeout` is the only
    # lever available. Do NOT answer a future flake here by raising the
    # threshold: shrink the window, or the assertion stops meaning anything.
    test "fails open (returns []) within its configured bound against an unresponsive resolver" do
      # 192.0.2.0/24 is TEST-NET-1 (RFC 5737): reserved and guaranteed
      # non-routable, so this never gets an answer — the same path a hung
      # resolver takes.
      {elapsed_us, result} =
        :timer.tc(fn ->
          Readiness.resolve_a(~c"example.invalid",
            nameservers: [{{192, 0, 2, 1}, 53}],
            timeout: 300,
            retry: 1
          )
        end)

      assert result == [], "an unresponsive resolver must fail open, not raise"
      assert elapsed_us < 2_000_000
    end
  end
end
