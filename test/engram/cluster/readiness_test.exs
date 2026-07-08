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
  end
end
