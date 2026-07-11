defmodule Engram.Observability.TraceSamplerTest do
  use ExUnit.Case, async: true

  alias Engram.Observability.TraceSampler

  @noise_paths ~w(/metrics /api/health /api/health/deep /socket/origin-probe/websocket)

  describe "drop?/1" do
    for path <- @noise_paths do
      test "drops root spans for noise path #{path}" do
        assert TraceSampler.drop?(%{"url.path": unquote(path)})
      end
    end

    test "keeps real endpoint paths" do
      refute TraceSampler.drop?(%{"url.path": "/api/sync/changes"})
      refute TraceSampler.drop?(%{"url.path": "/api/mcp"})
      # A prefix of a noise path must NOT match (exact-match only).
      refute TraceSampler.drop?(%{"url.path": "/api/healthz"})
      refute TraceSampler.drop?(%{"url.path": "/metrics/custom"})
    end

    test "keeps bare / — self-host serves the SPA index there" do
      refute TraceSampler.drop?(%{"url.path": "/"})
    end

    test "keeps spans that carry no url.path (child / internal spans)" do
      refute TraceSampler.drop?(%{})
      refute TraceSampler.drop?(%{"db.system": "postgresql", "db.statement": "SELECT 1"})
    end

    # should_sample runs on the hot path of every span; a crash would break
    # all tracing (or worse, request handling). It must be total against any
    # non-map shape (the :otel_sampler contract only ever delivers a map).
    test "tolerates non-map attribute shapes without raising" do
      refute TraceSampler.drop?([{:"url.path", "/metrics"}])
      refute TraceSampler.drop?(nil)
      refute TraceSampler.drop?("garbage")
    end
  end

  describe "should_sample/7" do
    setup do
      %{config: TraceSampler.setup(%{ratio: 1.0})}
    end

    test "drops a noise-path root span", %{config: config} do
      {decision, attrs, _tracestate} =
        TraceSampler.should_sample(
          %{},
          123,
          [],
          "GET",
          :server,
          %{"url.path": "/api/health"},
          config
        )

      assert decision == :drop
      assert attrs == []
    end

    test "delegates to the ratio sampler for real paths (sampled at 1.0)", %{config: config} do
      {decision, _attrs, _tracestate} =
        TraceSampler.should_sample(
          %{},
          123,
          [],
          "POST /api/sync/changes",
          :server,
          %{"url.path": "/api/sync/changes"},
          config
        )

      assert decision == :record_and_sample
    end

    test "delegate honours ratio 0.0 (drops real paths too)" do
      config = TraceSampler.setup(%{ratio: 0.0})

      {decision, _attrs, _tracestate} =
        TraceSampler.should_sample(
          %{},
          123,
          [],
          "GET",
          :server,
          %{"url.path": "/api/notes"},
          config
        )

      assert decision == :drop
    end
  end
end
