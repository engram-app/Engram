defmodule Engram.Vector.FilterRoundtripTest do
  @moduledoc """
  Review Focus 2 (Task 15.4): during the v5 pass a vault holds v3-shaped
  points (long `*_hmac` keys, base64) and v5 points (short keys, hex ids).
  Against a real Qdrant with strict mode ON, every filter path matches both
  formats, the nested long-tail filters match within one element, and
  tenants never cross.
  """
  use ExUnit.Case, async: false

  alias Engram.Indexing.PayloadV5
  alias Engram.Notes.FlatFields
  alias Engram.Notes.Note
  alias Engram.ServiceConfig
  alias Engram.Vector.FilterId
  alias Engram.Vector.Qdrant

  @moduletag :qdrant_integration

  @dims 8
  @vector List.duplicate(0.1, @dims)

  # ONE collection for the module: each collection with the 20 v5 indexes
  # costs CI's 2 GB tmpfs Qdrant hundreds of MB (a second one SIGBUSed it),
  # which is the footprint question `:v5_payload_format` waits on. Tests use
  # fresh random tenants, so they never see each other's points.
  setup_all do
    ServiceConfig.put_override(:qdrant_url, qdrant_url())
    ServiceConfig.put_override(:v5_payload_format, true)

    col =
      "engram_rt_#{System.get_env("MIX_TEST_PARTITION")}_#{System.unique_integer([:positive])}"

    :ok = Qdrant.ensure_collection(col, @dims)

    {:ok, %{status: 200}} =
      Req.patch("#{qdrant_url()}/collections/#{col}",
        json: %{strict_mode_config: %{enabled: true, unindexed_filtering_retrieve: false}}
      )

    Engram.QdrantIntegration.drop_on_exit(col)

    %{col: col}
  end

  setup do
    ServiceConfig.put_override(:qdrant_url, qdrant_url())
    ServiceConfig.put_override(:v5_payload_format, true)
    :ok
  end

  defp tenant do
    %{
      user_id: Ecto.UUID.generate(),
      vault_id: Ecto.UUID.generate(),
      fk: :crypto.strong_rand_bytes(32),
      path: :crypto.strong_rand_bytes(32),
      folder: :crypto.strong_rand_bytes(32),
      type: :crypto.strong_rand_bytes(32),
      tag: :crypto.strong_rand_bytes(32)
    }
  end

  defp v3_point(t) do
    %{
      id: Ecto.UUID.generate(),
      vector: %{"dense" => @vector},
      payload: %{
        user_id: t.user_id,
        vault_id: t.vault_id,
        path_hmac: Base.encode64(t.path),
        folder_hmac: Base.encode64(t.folder),
        type_hmac: Base.encode64(t.type),
        tags_hmac: [Base.encode64(t.tag)],
        fm_timestamp: 1_700_000_000,
        fm_created: 1_600_000_000
      }
    }
  end

  defp v5_point(t, yaml) do
    note = %Note{
      user_id: t.user_id,
      vault_id: t.vault_id,
      path_hmac: t.path,
      folder_hmac: t.folder,
      type_hmac: t.type,
      tags_hmac: [t.tag],
      created_at: ~U[2023-09-13 12:26:40Z],
      updated_at: ~U[2023-11-14 22:13:20Z]
    }

    flat = FlatFields.extract("---\n" <> yaml <> "---\nbody\n", t.fk)
    flat = FlatFields.put_key_ids(flat, key_ids(t))

    %{
      id: Ecto.UUID.generate(),
      vector: %{"dense" => @vector},
      payload: PayloadV5.build(note, flat)
    }
  end

  # The per-user dictionary ids (`FrontmatterKeys`) without a database: a
  # fixed list, the same for every tenant, which is exactly the case the
  # cross-tenant test needs (equal ids, different users).
  @user_keys ~w(phase other rating launch a b)
  defp key_ids(t),
    do:
      @user_keys
      |> Enum.with_index(64)
      |> Map.new(fn {k, i} -> {FilterId.key_hmac(t.fk, k), i} end)

  defp key_id(name), do: 64 + Enum.find_index(@user_keys, &(&1 == name))

  defp ids(col, opts) do
    {:ok, hits} = Qdrant.search(col, @vector, [limit: 10] ++ opts)
    hits |> Enum.map(& &1.qdrant_id) |> Enum.sort()
  end

  defp count(col, filter) do
    {:ok, %{status: 200, body: %{"result" => %{"count" => n}}}} =
      Req.post("#{qdrant_url()}/collections/#{col}/points/count",
        json: %{filter: filter, exact: true}
      )

    n
  end

  test "every filter path matches both formats", %{col: col} do
    t = tenant()
    old = v3_point(t)
    new = v5_point(t, "updated: 2023-11-14T22:13:20Z\n")
    :ok = Qdrant.upsert_points(col, [old, new])
    both = Enum.sort([old.id, new.id])
    base = [user_id: t.user_id, vault_id: t.vault_id]

    assert ids(col, base) == both
    assert ids(col, base ++ [folder_hmac: Base.encode64(t.folder)]) == both
    assert ids(col, base ++ [type_hmac: Base.encode64(t.type)]) == both
    assert ids(col, base ++ [tags_hmac: [Base.encode64(t.tag)]]) == both
    assert ids(col, base ++ [vault_id: [t.vault_id]]) == both
    assert ids(col, base ++ [fm_timestamp_gte: 1_699_999_999]) == both

    path = Base.encode64(t.path)
    assert {:ok, 2} = Qdrant.count_by_note(col, t.user_id, t.vault_id, path)
    assert :ok = Qdrant.delete_by_note(col, t.user_id, t.vault_id, path)
    assert {:ok, 0} = Qdrant.count_by_note(col, t.user_id, t.vault_id, path)
  end

  test "repath rewrites each format with its own keys", %{col: col} do
    t = tenant()
    :ok = Qdrant.upsert_points(col, [v3_point(t), v5_point(t, "")])
    new_path = :crypto.strong_rand_bytes(32)
    old = Base.encode64(t.path)

    assert :ok =
             Qdrant.set_payload_by_filter(col, t.user_id, t.vault_id, old, %{
               "path_hmac" => Base.encode64(new_path),
               "folder_hmac" => nil
             })

    assert {:ok, 2} = Qdrant.count_by_note(col, t.user_id, t.vault_id, Base.encode64(new_path))
    assert count(col, %{must: [%{key: "p", match: %{value: FilterId.from_hmac(new_path)}}]}) == 1

    assert count(col, %{
             must: [
               %{is_empty: %{key: "f"}},
               %{key: "u", match: %{value: FilterId.uuid(t.user_id)}}
             ]
           }) == 1

    assert count(col, %{must: [%{key: "path_hmac", match: %{value: Base.encode64(new_path)}}]}) ==
             1
  end

  # Review H2: the v5 refresh replaces the payload, so a removed key is gone,
  # and a refresh that lands before the debounced repath leaves no stale `f`.
  test "a refresh replaces the payload; rename to root holds either order", %{col: col} do
    t = tenant()
    point = v5_point(t, "status: draft\n")
    :ok = Qdrant.upsert_points(col, [point])
    u = %{key: "u", match: %{value: FilterId.uuid(t.user_id)}}
    assert count(col, %{must: [u, %{is_empty: %{key: "s"}}]}) == 0

    moved = %{v5_point(t, "") | id: point.id}
    new_path = :crypto.strong_rand_bytes(32)
    payload = moved.payload |> Map.delete("f") |> Map.put("p", FilterId.from_hmac(new_path))
    assert :ok = Qdrant.overwrite_payload(col, [point.id], payload)

    assert count(col, %{must: [u, %{is_empty: %{key: "s"}}]}) == 1
    assert count(col, %{must: [u, %{is_empty: %{key: "f"}}]}) == 1

    # The repath that follows filters on the old path and matches nothing.
    assert :ok =
             Qdrant.set_payload_by_filter(col, t.user_id, t.vault_id, Base.encode64(t.path), %{
               "path_hmac" => Base.encode64(new_path),
               "folder_hmac" => nil
             })

    assert count(col, %{must: [u, %{is_empty: %{key: "f"}}]}) == 1

    assert count(col, %{must: [u, %{key: "p", match: %{value: FilterId.from_hmac(new_path)}}]}) ==
             1
  end

  test "with legacy fields off only the v5 point matches", %{col: col} do
    t = tenant()
    new = v5_point(t, "")
    :ok = Qdrant.upsert_points(col, [v3_point(t), new])
    ServiceConfig.put_override(:legacy_filter_fields, false)

    assert ids(col, user_id: t.user_id, vault_id: t.vault_id) == [new.id]
  end

  test "nested user-key filters match within one element", %{col: col} do
    t = tenant()
    draft = v5_point(t, "phase: draft\nrating: 4.5\nlaunch: 2026-11-01\n")
    other = v5_point(t, "phase: stable\nother: draft\nrating: 3\nlaunch: 2027-01-01\n")
    :ok = Qdrant.upsert_points(col, [draft, other])

    v = &FilterId.attr_value(t.fk, &1)
    u = %{key: "u", match: %{value: FilterId.uuid(t.user_id)}}
    f = fn name, value -> Qdrant.attr_filter(key_id(name), value) end

    assert count(col, %{must: [u, f.("phase", {:h, v.("draft")})]}) == 1
    assert count(col, %{must: [u, f.("phase", {:h, [v.("draft"), v.("stable")]})]}) == 2
    assert count(col, %{must: [u, f.("rating", {:n, gte: 4})]}) == 1

    lt = DateTime.to_unix(~U[2026-12-01 00:00:00Z])
    assert count(col, %{must: [u, f.("launch", {:d, lt: lt})]}) == 1
  end

  # The key and its value must match in the SAME fa entry: `a: 1, b: 5`
  # is not a note where `a = 5`.
  test "a value under another key never matches", %{col: col} do
    t = tenant()
    :ok = Qdrant.upsert_points(col, [v5_point(t, "a: 1\nb: 5\n")])
    u = %{key: "u", match: %{value: FilterId.uuid(t.user_id)}}
    eq = fn name, n -> Qdrant.attr_filter(key_id(name), {:n, gte: n, lte: n}) end

    assert count(col, %{must: [u, eq.("a", 1)]}) == 1
    assert count(col, %{must: [u, eq.("b", 5)]}) == 1
    assert count(col, %{must: [u, eq.("a", 5)]}) == 0
    assert count(col, %{must: [u, eq.("b", 1)]}) == 0
  end

  test "cross tenant: the same status never matches the other user", %{col: col} do
    a = tenant()
    b = tenant()
    pa = v5_point(a, "status: draft\nphase: draft\n")
    pb = v5_point(b, "status: draft\nphase: draft\n")
    :ok = Qdrant.upsert_points(col, [pa, pb])

    refute pa.payload["s"] == pb.payload["s"]

    s = %{key: "s", match: %{value: FilterId.attr_value(a.fk, "draft")}}
    ua = %{key: "u", match: %{value: FilterId.uuid(a.user_id)}}
    assert count(col, %{must: [ua, s]}) == 1
    assert count(col, %{must: [s]}) == 1

    # Both users have `phase` at the SAME key id; the value id differs per
    # user and the tenant condition separates them.
    phase = Qdrant.attr_filter(key_id("phase"), {:h, FilterId.attr_value(a.fk, "draft")})
    assert count(col, %{must: [ua, phase]}) == 1

    ub = %{key: "u", match: %{value: FilterId.uuid(b.user_id)}}
    assert count(col, %{must: [ub, s]}) == 0
    assert count(col, %{must: [ub, phase]}) == 0
  end

  defp qdrant_url do
    System.get_env("QDRANT_URL") ||
      Application.get_env(:engram, :qdrant_url, "http://localhost:6333")
  end
end
