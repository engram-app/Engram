defmodule Engram.SearchFilterTelemetryTest do
  @moduledoc """
  Filter telemetry (#2697): which filter keys a search used, how its scope
  resolved, and which surface asked. Keys only, never values.
  """
  use Engram.DataCase, async: false

  alias Engram.Search
  alias Engram.ServiceConfig

  require OpenTelemetry.Tracer, as: Tracer
  require Record
  @fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecordp(:span, @fields)

  @stop [:engram, :search, :request, :stop]
  @resolve [:engram, :search, :filter_resolve]
  @page [:engram, :search, :filter_page]

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:qdrant_search_timeout, 30_000)
    # The `n` index is there, so a filter resolves to a note-id scope.
    Engram.QdrantStub.stub_healthy(bypass, "engram_notes",
      payload_schema: fn -> %{"n" => %{"data_type" => "uuid"}} end
    )

    ref = :telemetry_test.attach_event_handlers(self(), [@stop, @resolve, @page])
    on_exit(fn -> :telemetry.detach(ref) end)
    {:ok, user} = insert(:user) |> Engram.Crypto.ensure_user_dek()
    %{bypass: bypass, user: user, vault: insert(:vault, user: user), ref: ref}
  end

  test "an unfiltered search: filtered false, scope none, no resolve timing",
       %{bypass: bypass, user: user, vault: vault, ref: ref} do
    Bypass.expect_once(bypass, "POST", "/collections/engram_notes/points/query", fn conn ->
      Plug.Conn.send_resp(conn, 200, ~s({"result":{"points":[]}}))
    end)

    assert {:ok, []} = Search.search(user, vault, "iron", mode: :keyword, surface: "mcp")

    assert_received {@stop, ^ref, %{result_count: 0},
                     %{filtered: false, scope: :none, surface: :mcp, empty: true}}

    refute_received {@resolve, ^ref, _, _}
  end

  test "a filtered search tags the keys and scope on the span and the counter",
       %{user: user, vault: vault, ref: ref} do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

    Tracer.with_span "test.request" do
      # No note in that folder: Postgres resolves the scope to zero ids, so
      # no Qdrant request is made.
      assert {:ok, []} =
               Search.search(user, vault, "iron",
                 mode: :keyword,
                 folder: "Nowhere",
                 tags: ["x"],
                 surface: "api"
               )
    end

    assert_received {@stop, ^ref, _, %{filtered: true, scope: :ids, surface: :rest}}
    assert_received {@resolve, ^ref, %{duration: d}, %{scope: :ids}} when is_integer(d)

    assert_receive {:span, span(name: "test.request", attributes: attrs)}, 2_000
    attrs = :otel_attributes.map(attrs)
    assert attrs["engram.search.filters"] == "folder,tags"
    assert attrs["engram.search.scope"] == "ids"
    refute inspect(attrs) =~ "Nowhere"
  end

  test "surface labels: the plugin, the web app and internal callers",
       %{user: user, vault: vault, ref: ref} do
    for {surface, label} <- [{"obsidian_sync", :plugin}, {"web", :web}, {nil, :internal}] do
      opts = [mode: :keyword, folder: "Nowhere"] ++ if(surface, do: [surface: surface], else: [])
      assert {:ok, []} = Search.search(user, vault, "iron", opts)
      assert_received {@stop, ^ref, _, %{surface: ^label}}
    end

    assert {:ok, []} =
             Search.search(user, vault, "iron",
               mode: :keyword,
               folder: "Nowhere",
               surface: "mcp",
               internal: true
             )

    assert_received {@stop, ^ref, _, %{surface: :internal}}
  end

  test "a filter-only listing counts once on its own event, not as a search",
       %{user: user, vault: vault, ref: ref} do
    other = insert(:vault, user: user)

    # A map filter (`NoteFilter.filter`), surface read from it.
    assert {:ok, [{^vault, %{notes: []}}, {^other, %{notes: []}}]} =
             Search.filter_page(user, [vault, other], %{folder: "Nowhere", surface: "mcp"})

    assert_received {@page, ^ref, %{result_count: 0}, %{status: :ok, surface: :mcp, empty: true}}
    refute_received {@page, ^ref, _, _}
    refute_received {@stop, ^ref, _, _}
  end
end
