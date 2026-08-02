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

    # The wall-clock half of this test is GONE. History, so it does not come
    # back:
    #
    #   - originally ran the production 1_500ms timeout and asserted < 4s.
    #     Went red twice on a loaded machine at 4.08s and 5.50s (#1158).
    #   - #1177 split the arithmetic invariant out (the test above) and shrank
    #     this one to a 300ms nominal against a 2s assertion — ~6.6x headroom.
    #   - it went red again anyway on 2026-08-02, at 2,224,917us.
    #
    # Shrinking the window a third time would not help, because the overshoot
    # was never the DNS call. 300ms nominal overrunning to 2.2s is ~7x, and
    # that is scheduler starvation in a parallel suite, not a slow resolver.
    # There is no window small enough to outrun CPU contention.
    #
    # The deeper problem is that the assertion was not earning its keep:
    #
    #   1. The invariant it nominally guarded — "we did not ship an unbounded
    #      resolver" — is the arithmetic test above. That one fails the moment
    #      someone raises @resolve_timeout_ms, and cannot flake.
    #   2. What remained was proof that :inet_res honours its own `timeout`
    #      option. That is OTP's contract, not ours. resolve_a/2 is a
    #      Keyword.merge and a stdlib call with no logic in between.
    #   3. It could not even catch the one wiring bug worth catching. Delete
    #      the Keyword.merge so opts never reach :inet_res, and the call falls
    #      back to the 1_500ms default — still under the 2s assertion. Green.
    #
    # So it cost three red builds and bought nothing the arithmetic test does
    # not already buy. What IS ours, and IS deterministic, is failing open:
    # returning [] instead of raising when the resolver never answers. That is
    # the Enum.map over a dead lookup, and it is what the test below asserts.
    #
    # If you ever need to prove the bound empirically again, do it as a
    # benchmark or a manual check — not as a wall-clock assertion inside the
    # parallel suite.
    test "fails open (returns []) against an unresponsive resolver" do
      # 192.0.2.0/24 is TEST-NET-1 (RFC 5737): reserved and guaranteed
      # non-routable, so this never gets an answer — the same path a hung
      # resolver takes. Kept short so the suite does not wait on it; the
      # duration is incidental now, not asserted.
      result =
        Readiness.resolve_a(~c"example.invalid",
          nameservers: [{{192, 0, 2, 1}, 53}],
          timeout: 100,
          retry: 1
        )

      assert result == [], "an unresponsive resolver must fail open, not raise"
    end

    # This is the coverage the wall-clock assertion was supposed to provide and
    # never did: proof that the shipped bound actually REACHES :inet_res.
    # Deterministic, no clock, and it fails on the exact regression the timing
    # test slept through — dropping the merge so lookups silently run on
    # :inet_res's own defaults while resolve_budget_ms/0 keeps reporting the
    # intended number.
    test "the shipped bound is actually handed to the resolver" do
      opts = Readiness.resolve_opts()

      assert Keyword.fetch!(opts, :timeout) * Keyword.fetch!(opts, :retry) ==
               Readiness.resolve_budget_ms(),
             "resolve_a/2 must pass the same budget that resolve_budget_ms/0 advertises, " <>
               "got #{inspect(opts)} against #{Readiness.resolve_budget_ms()}ms"
    end

    test "caller options override the shipped defaults" do
      opts = Readiness.resolve_opts(timeout: 50, nameservers: [{{192, 0, 2, 1}, 53}])

      assert Keyword.fetch!(opts, :timeout) == 50
      assert Keyword.fetch!(opts, :nameservers) == [{{192, 0, 2, 1}, 53}]
      # Unspecified defaults survive the merge.
      assert Keyword.fetch!(opts, :retry) == 1
    end
  end
end
