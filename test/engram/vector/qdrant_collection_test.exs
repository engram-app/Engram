defmodule Engram.Vector.QdrantCollectionTest do
  use ExUnit.Case, async: true

  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    ServiceConfig.put_override(:v5_payload_format, true)
    %{bypass: bypass}
  end

  test "with the v5 format off, a new collection is exactly main's", %{bypass: bypass} do
    ServiceConfig.put_override(:v5_payload_format, false)
    test_pid = self()

    Bypass.expect_once(bypass, "PUT", "/collections/c1", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      refute Map.has_key?(Jason.decode!(body)["vectors"]["dense"], "datatype")
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    Bypass.expect(bypass, "PUT", "/collections/c1/index", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:index, Jason.decode!(body)["field_name"]})
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
    end)

    assert :ok = Qdrant.ensure_collection("c1", 1024)

    # The 6 legacy keyword, note_id and 2 integer indexes (main's set).
    fields =
      for _ <- 1..9 do
        assert_receive {:index, field}
        field
      end

    refute_receive {:index, _}
    assert "note_id" in fields
  end

  describe "tenant layout by server version (Task 8.1)" do
    # The layout follows the server version only while the app manages the
    # collection layout (`:qdrant_reconcile_config`, off suite-wide).
    setup %{bypass: bypass} do
      ServiceConfig.put_override(:qdrant_reconcile_config, true)
      Bypass.stub(bypass, "PATCH", "/collections/c1", &Plug.Conn.send_resp(&1, 200, "{}"))
      :ok
    end

    defp create_on(bypass, version) do
      test_pid = self()
      Bypass.stub(bypass, "GET", "/collections/c1", &Plug.Conn.send_resp(&1, 500, "{}"))

      Bypass.stub(bypass, "GET", "/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{version: version}))
      end)

      Bypass.expect_once(bypass, "PUT", "/collections/c1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:create, Jason.decode!(body)})
        Plug.Conn.send_resp(conn, 200, "{}")
      end)

      Bypass.stub(bypass, "PUT", "/collections/c1/index", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"field_name" => f, "field_schema" => s} = Jason.decode!(body)
        send(test_pid, {:index, f, s})
        Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
      end)

      Qdrant.ensure_collection("c1", 1024)
      assert_receive {:create, create}
      {create, collect_indexes(%{})}
    end

    defp collect_indexes(acc) do
      receive do
        {:index, f, s} -> collect_indexes(Map.put(acc, f, s))
      after
        50 -> acc
      end
    end

    test "1.19.2: per-tenant graph at create, tenant + on-disk index schemas",
         %{bypass: bypass} do
      {create, indexes} = create_on(bypass, "1.19.2")

      # The global graph stays until Task 18.1 flips :qdrant_tenant_graph.
      refute Map.has_key?(create, "hnsw_config")
      assert create["optimizers_config"]["max_segment_size"] == 1_000_000
      assert indexes["u"] == %{"type" => "uuid", "is_tenant" => true, "on_disk" => true}
      assert indexes["vault_id"]["enable_hnsw"] == false
      refute Map.has_key?(indexes, "note_id")
    end

    test "version unknown: a missing collection is not created (next boot retries)",
         %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/", &Plug.Conn.send_resp(&1, 503, "{}"))
      Bypass.stub(bypass, "GET", "/collections/c1", &Plug.Conn.send_resp(&1, 404, "{}"))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :qdrant_version_unknown} = Qdrant.ensure_collection("c1", 1024)
        end)

      assert log =~ "qdrant version unreadable"
    end

    test "version unknown: an existing collection is still verified", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/", &Plug.Conn.send_resp(&1, 503, "{}"))

      Bypass.stub(bypass, "PUT", "/collections/c1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(409, ~s({"status":{"error":"already exists"}}))
      end)

      Bypass.stub(bypass, "GET", "/collections/c1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, existing_body(%{}))
      end)

      Bypass.stub(bypass, "PUT", "/collections/c1/index", fn conn ->
        Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
      end)

      # The post-verify reconcile's reads; not under test here.
      Bypass.stub(bypass, "GET", "/sys_metrics", &Plug.Conn.send_resp(&1, 404, ""))
      Bypass.stub(bypass, "GET", "/collections/c1/memory", &Plug.Conn.send_resp(&1, 404, ""))

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Qdrant.ensure_collection("c1", 1024)
      end)
    end

    test "1.18.2 (prod's old cluster): today's create body and indexes", %{bypass: bypass} do
      ServiceConfig.put_override(:v5_payload_format, false)
      {create, indexes} = create_on(bypass, "1.18.2")

      refute Map.has_key?(create, "hnsw_config")
      assert create["optimizers_config"] == %{"max_optimization_threads" => 1}
      assert indexes["user_id"] == "keyword"
      assert indexes["note_id"] == "keyword"
      assert indexes["fm_timestamp"] == "integer"
    end
  end

  # All tenant-scoped filters target payload fields that Qdrant Cloud
  # strict-mode requires an index for. ensure_collection must create them
  # (idempotently) or every filtered op 400s on Cloud. See #626. `type_hmac`
  # is the OKF frontmatter blind index (keyword); `fm_timestamp`/`fm_created`
  # are the OKF frontmatter dates (integer, range-filterable). `folder_hmac`
  # and `tags_hmac` are the folder/tag search filters (#1609).
  # `note_id` is gone: no read path filters on it (v5, spec 3.3b).
  @indexed_fields ~w(user_id vault_id path_hmac type_hmac folder_hmac tags_hmac)
  @integer_indexed_fields ~w(fm_timestamp fm_created)
  # The v5 short-key indexes, on disk, with their typed schemas.
  @v5_fields Engram.Vector.PayloadKeys.index_fields()
  @all_count length(@indexed_fields) + length(@integer_indexed_fields) + length(@v5_fields)

  # A named-shape collection_info body carrying the given payload_schema.
  defp existing_body(payload_schema) do
    Jason.encode!(%{
      result: %{
        config: %{
          params: %{
            vectors: %{"dense" => %{size: 1024, distance: "Cosine"}},
            sparse_vectors: %{"keyword" => %{modifier: "idf"}}
          }
        },
        payload_schema: payload_schema
      }
    })
  end

  defp expect_existing(bypass, col, payload_schema) do
    Bypass.expect_once(bypass, "PUT", "/collections/#{col}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(409, ~s({"status":{"error":"already exists"}}))
    end)

    Bypass.expect_once(bypass, "GET", "/collections/#{col}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, existing_body(payload_schema))
    end)
  end

  defp schema_for(fields, type), do: Map.new(fields, &{&1, %{data_type: type}})

  # Stub the payload-index endpoint so tests asserting other behaviour don't
  # fail on the index PUTs ensure_collection now fires.
  defp stub_indexes(bypass, col) do
    Bypass.stub(bypass, "PUT", "/collections/#{col}/index", fn conn ->
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
    end)
  end

  test "creates a collection with named dense + keyword sparse(idf)", %{bypass: bypass} do
    stub_indexes(bypass, "c1")

    Bypass.expect_once(bypass, "PUT", "/collections/c1", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      assert json["vectors"]["dense"]["size"] == 1024
      assert json["vectors"]["dense"]["distance"] == "Cosine"
      assert json["sparse_vectors"]["keyword"]["modifier"] == "idf"
      assert json["vectors"]["dense"]["datatype"] == "float16"
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    assert :ok = Qdrant.ensure_collection("c1", 1024)
  end

  test "creates a keyword payload index for every filtered field after create",
       %{bypass: bypass} do
    test_pid = self()

    Bypass.expect_once(bypass, "PUT", "/collections/c1", fn conn ->
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    Bypass.expect(bypass, "PUT", "/collections/c1/index", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      send(test_pid, {:index, json["field_name"], json["field_schema"]})
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
    end)

    assert :ok = Qdrant.ensure_collection("c1", 1024)

    for field <- @indexed_fields do
      assert_receive {:index, ^field, "keyword"}
    end

    for field <- @integer_indexed_fields do
      assert_receive {:index, ^field, "integer"}
    end

    for {field, schema} <- @v5_fields do
      assert_receive {:index, ^field, ^schema}
    end

    refute_received {:index, "note_id", _}
  end

  # Each waited index create is a fsync'd round trip; nine in a row on a
  # fresh collection spent the 60s CI test budget on a busy disk (the #2064
  # stall). Index ops apply in order on each shard, so waiting on the LAST
  # one means all are built (checked on 1.19.2: 9 fields over 3000 points on
  # 2 shards, all indexed when the last create returned).
  test "only the last payload index create waits", %{bypass: bypass} do
    test_pid = self()

    Bypass.expect_once(bypass, "PUT", "/collections/c1", fn conn ->
      Plug.Conn.send_resp(conn, 200, "{}")
    end)

    Bypass.expect(bypass, "PUT", "/collections/c1/index", fn conn ->
      send(test_pid, {:wait, URI.decode_query(conn.query_string)["wait"]})
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
    end)

    assert :ok = Qdrant.ensure_collection("c1", 1024)

    waits =
      for _ <- 1..@all_count do
        assert_receive {:wait, wait}
        wait
      end

    assert List.last(waits) == "true"
    assert Enum.all?(Enum.drop(waits, -1), &(&1 == "false"))
    refute_received {:wait, _}
  end

  test "does NOT re-create payload indexes an existing collection already has",
       %{bypass: bypass} do
    test_pid = self()

    expect_existing(
      bypass,
      "c1",
      schema_for(@indexed_fields, "keyword")
      |> Map.merge(schema_for(@integer_indexed_fields, "integer"))
      |> Map.merge(Map.new(@v5_fields, fn {f, s} -> {f, %{data_type: s["type"]}} end))
    )

    # If the steady-state path wrongly (re-)created indexes, this fires.
    Bypass.stub(bypass, "PUT", "/collections/c1/index", fn conn ->
      send(test_pid, :index_called)
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
    end)

    assert :ok = Qdrant.ensure_collection("c1", 1024)
    refute_receive :index_called
  end

  # #1609: indexes were only created on a fresh collection, so any field added
  # to the list later never reached a collection that already existed. Prod
  # carried only these four, and strict mode 400s a filter on the rest.
  # LEGACY_FILTER_FIELDS=false (the v3 cluster): boot creates only the v5
  # indexes, and an existing legacy index is left alone, never deleted (a
  # DELETE would hit Bypass unstubbed and fail the test).
  test "legacy filters off: boot creates no legacy index and deletes none", %{bypass: bypass} do
    ServiceConfig.put_override(:legacy_filter_fields, false)
    test_pid = self()

    expect_existing(bypass, "c1", schema_for(~w(user_id vault_id), "keyword"))

    Bypass.expect(bypass, "PUT", "/collections/c1/index", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:index, Jason.decode!(body)["field_name"]})
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
    end)

    assert :ok = Qdrant.ensure_collection("c1", 1024)

    for {field, _} <- @v5_fields, do: assert_receive({:index, ^field})

    for field <- @indexed_fields ++ @integer_indexed_fields ++ ["note_id"] do
      refute_received {:index, ^field}
    end
  end

  test "creates the payload indexes an existing collection is missing", %{bypass: bypass} do
    test_pid = self()
    present = ~w(user_id vault_id note_id path_hmac)

    expect_existing(bypass, "c1", schema_for(present, "keyword"))

    Bypass.expect(bypass, "PUT", "/collections/c1/index", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      json = Jason.decode!(body)
      send(test_pid, {:index, json["field_name"], json["field_schema"]})
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
    end)

    assert :ok = Qdrant.ensure_collection("c1", 1024)

    for field <- @indexed_fields -- present do
      assert_receive {:index, ^field, "keyword"}
    end

    for field <- @integer_indexed_fields do
      assert_receive {:index, ^field, "integer"}
    end

    for field <- present do
      refute_received {:index, ^field, _}
    end
  end

  test "an existing collection with no payload_schema gets every index", %{bypass: bypass} do
    test_pid = self()

    expect_existing(bypass, "c1", nil)

    Bypass.expect(bypass, "PUT", "/collections/c1/index", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:index, Jason.decode!(body)["field_name"]})
      Plug.Conn.send_resp(conn, 200, ~s({"status":"ok"}))
    end)

    assert :ok = Qdrant.ensure_collection("c1", 1024)

    for field <- @indexed_fields ++ @integer_indexed_fields ++ Enum.map(@v5_fields, &elem(&1, 0)) do
      assert_receive {:index, ^field}
    end
  end

  test "a failed index create on an existing collection is returned, not swallowed",
       %{bypass: bypass} do
    expect_existing(bypass, "c1", schema_for(~w(user_id vault_id note_id path_hmac), "keyword"))

    Bypass.expect_once(bypass, "PUT", "/collections/c1/index", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(500, ~s({"status":{"error":"boom"}}))
    end)

    assert {:error, {500, _}} = Qdrant.ensure_collection("c1", 1024)
  end

  # H2 — 409 "already exists" must verify the collection shape, not blindly
  # accept it. A legacy single-unnamed-vector collection would 400 every
  # named-vector upsert/search silently without this guard.

  test "409 + named-shape GET → :ok (collection shape is compatible)", %{bypass: bypass} do
    stub_indexes(bypass, "c1")

    Bypass.expect_once(bypass, "PUT", "/collections/c1", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(409, ~s({"status":{"error":"already exists"}}))
    end)

    named_shape_body =
      Jason.encode!(%{
        result: %{
          config: %{
            params: %{
              vectors: %{"dense" => %{size: 1024, distance: "Cosine"}},
              sparse_vectors: %{"keyword" => %{modifier: "idf"}}
            }
          }
        }
      })

    Bypass.expect_once(bypass, "GET", "/collections/c1", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, named_shape_body)
    end)

    assert :ok = Qdrant.ensure_collection("c1", 1024)
  end

  test "409 + legacy-shape GET → {:error, :incompatible_collection_schema}", %{bypass: bypass} do
    Bypass.expect_once(bypass, "PUT", "/collections/c1", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(409, ~s({"status":{"error":"already exists"}}))
    end)

    # Legacy: single unnamed-vector shape — top-level "size"/"distance" keys
    # inside "vectors", no "dense" sub-key, no "sparse_vectors".
    legacy_shape_body =
      Jason.encode!(%{
        result: %{
          config: %{
            params: %{
              vectors: %{"size" => 1024, "distance" => "Cosine"}
            }
          }
        }
      })

    Bypass.expect_once(bypass, "GET", "/collections/c1", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, legacy_shape_body)
    end)

    assert {:error, {:incompatible_collection_schema, "c1"}} =
             Qdrant.ensure_collection("c1", 1024)
  end
end
