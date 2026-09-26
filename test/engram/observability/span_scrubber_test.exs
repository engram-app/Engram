defmodule Engram.Observability.SpanScrubberTest do
  use ExUnit.Case, async: false

  alias Engram.Observability.SpanScrubber

  require OpenTelemetry.Tracer, as: Tracer
  require Record
  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)

  @canary_path "/api/notes/Secret%20Folder/Canary%20Title.md"

  describe "scrub/1" do
    test "a wildcard route keeps its template, never the user's path" do
      attrs =
        SpanScrubber.scrub(%{
          :"http.request.method" => :DELETE,
          :"url.path" => "/api/folders/Intelligence/Chats"
        })

      assert attrs[:"url.path"] == "/api/folders/*path"
      refute inspect(attrs) =~ "Intelligence"
      refute inspect(attrs) =~ "Chats"
    end

    test "a wildcard route gets a stable, opaque path ref plus depth and extension" do
      a = SpanScrubber.scrub(%{:"http.request.method" => :GET, :"url.path" => @canary_path})
      b = SpanScrubber.scrub(%{:"http.request.method" => :GET, :"url.path" => @canary_path})

      other =
        SpanScrubber.scrub(%{:"http.request.method" => :GET, :"url.path" => "/api/notes/Other.md"})

      assert a[:"engram.path.ref"] =~ ~r/\A[0-9a-f]{12}\z/
      assert a[:"engram.path.ref"] == b[:"engram.path.ref"]
      refute a[:"engram.path.ref"] == other[:"engram.path.ref"]
      assert a[:"engram.path.depth"] == 2
      assert a[:"engram.path.ext"] == "md"
      assert other[:"engram.path.depth"] == 1
    end

    test "an extension-less wildcard path reports no extension" do
      attrs =
        SpanScrubber.scrub(%{
          :"http.request.method" => :DELETE,
          :"url.path" => "/api/folders/Agent%20Client"
        })

      refute Map.has_key?(attrs, :"engram.path.ext")
      assert attrs[:"engram.path.depth"] == 1
    end

    test "a static route passes through untouched and gets no ref" do
      attrs =
        SpanScrubber.scrub(%{
          :"http.request.method" => :GET,
          :"url.path" => "/api/folders/explicit"
        })

      assert attrs[:"url.path"] == "/api/folders/explicit"
      refute Map.has_key?(attrs, :"engram.path.ref")
    end

    test "an unmatched path is replaced, since a 404 can carry anything" do
      attrs =
        SpanScrubber.scrub(%{
          :"http.request.method" => :GET,
          :"url.path" => "/Secret%20Folder/x.md"
        })

      assert attrs[:"url.path"] == "unmatched"
    end

    test "socket upgrade paths are kept (fixed strings, no user data)" do
      for p <- ["/socket/websocket", "/socket/device/websocket"] do
        assert SpanScrubber.scrub(%{:"http.request.method" => :GET, :"url.path" => p})[
                 :"url.path"
               ] == p
      end
    end

    test "the query string is dropped (tokens, search terms, paths)" do
      attrs =
        SpanScrubber.scrub(%{
          :"http.request.method" => :GET,
          :"url.path" => "/socket/websocket",
          :"url.query" => "token=secret-token&q=private+search"
        })

      refute Map.has_key?(attrs, :"url.query")
    end

    test "client and peer IPs are truncated to /24 (v4) and /48 (v6)" do
      v4 =
        SpanScrubber.scrub(%{
          :"client.address" => "203.0.113.77",
          :"network.peer.address" => "10.0.4.19"
        })

      assert v4[:"client.address"] == "203.0.113.0"
      assert v4[:"network.peer.address"] == "10.0.4.0"

      v6 = SpanScrubber.scrub(%{:"client.address" => "2001:db8:85a3:8d3:1319:8a2e:370:7348"})
      assert v6[:"client.address"] == "2001:db8:85a3::"
    end

    test "a non-IP client address is dropped rather than passed through" do
      refute Map.has_key?(
               SpanScrubber.scrub(%{:"client.address" => "not-an-ip"}),
               :"client.address"
             )
    end

    test "spans without HTTP attributes are returned unchanged" do
      attrs = %{:"db.system" => "postgresql", :"engram.event_type" => "note_changed"}
      assert SpanScrubber.scrub(attrs) == attrs
    end

    test "a missing method still scrubs the path (fail closed)" do
      assert SpanScrubber.scrub(%{:"url.path" => @canary_path})[:"url.path"] == "unmatched"
    end
  end

  describe "wired as a span processor" do
    setup do
      :application.set_env(:opentelemetry, :traces_exporter, {:otel_exporter_pid, self()})
      :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
      :ok
    end

    test "no exported span attribute carries the canary path, query, or full IP" do
      attrs = %{
        :"http.request.method" => :GET,
        :"url.path" => @canary_path,
        :"url.query" => "token=canary-token",
        :"client.address" => "203.0.113.77"
      }

      Tracer.with_span "GET", %{kind: :server, attributes: attrs} do
        :ok
      end

      assert_receive {:span, record}, 2_000
      exported = record |> span(:attributes) |> :otel_attributes.map() |> inspect()

      for secret <- ["Canary", "Secret", "canary-token", "203.0.113.77"] do
        refute exported =~ secret, "exported span leaked #{inspect(secret)}: #{exported}"
      end

      assert exported =~ "/api/notes/*path"
    end
  end
end
