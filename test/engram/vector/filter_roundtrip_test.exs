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
  # costs CI's 2 GB tmpfs Qdrant hundreds of MB (a second one SIGBUSed it).
  # Tests use fresh random tenants, so they never see each other's points.
  setup_all do
    ServiceConfig.put_override(:qdrant_url, qdrant_url())

    col =
      "engram_rt_#{System.get_env("MIX_TEST_PARTITION")}_#{System.unique_integer([:positive])}_" <>
        Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

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
    # The per-note filters' `n` arm (`config/test.exs` turns its probe off
    # for the Bypass suites). Every per-note call here goes through it.
    ServiceConfig.put_override(:qdrant_note_id_filter, true)
    Engram.Cache.clear_local(:note_id_filter)
    on_exit(fn -> Engram.Cache.clear_local(:note_id_filter) end)
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

  defp v5_point(t, yaml, note_id \\ nil) do
    note = %Note{
      id: note_id,
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

    # Neither point carries `n` (v3 never does, this v5 one has no note id),
    # so the per-note filters match both by path, as before `n` existed.
    path = Base.encode64(t.path)
    id = Ecto.UUID.generate()
    assert {:ok, 2} = Qdrant.count_by_note(col, t.user_id, t.vault_id, id, path)
    assert :ok = Qdrant.delete_by_note(col, t.user_id, t.vault_id, id, path)
    assert {:ok, 0} = Qdrant.count_by_note(col, t.user_id, t.vault_id, id, path)
  end

  # An R3a chunk point: `n`, no path key.
  defp r3a_point(t, note_id) do
    point = v5_point(t, "", note_id)
    %{point | payload: Map.delete(point.payload, "p")}
  end

  defp left(col, t), do: ids(col, user_id: t.user_id, vault_id: t.vault_id)

  test "a note's points match by n, and by path only without n", %{col: col} do
    t = tenant()
    id = Ecto.UUID.generate()
    [v3, v5, r3a] = [v3_point(t), v5_point(t, "", id), r3a_point(t, id)]
    :ok = Qdrant.upsert_points(col, [v3, v5, r3a])
    path = Base.encode64(t.path)

    assert {:ok, 3} = Qdrant.count_by_note(col, t.user_id, t.vault_id, id, path)

    assert :ok = Qdrant.delete_by_note_except(col, t.user_id, t.vault_id, id, path, [r3a.id])
    assert left(col, t) == [r3a.id]

    assert :ok = Qdrant.delete_by_note_except(col, t.user_id, t.vault_id, id, path, [v5.id])
    assert left(col, t) == []

    :ok = Qdrant.upsert_points(col, [r3a])
    assert :ok = Qdrant.delete_by_note(col, t.user_id, t.vault_id, id, path)
    assert {:ok, 0} = Qdrant.count_by_note(col, t.user_id, t.vault_id, id, path)
  end

  # Rename swap: note A left path X, note B moved onto X. A's old-path
  # delete must not reach B's points. A point with `n` is matched by `n`
  # only; a point with no `n` can only be matched by path (as before).
  test "a note's old path never reaches another note's points that carry n", %{col: col} do
    t = tenant()
    [a, b] = [Ecto.UUID.generate(), Ecto.UUID.generate()]
    b_point = v5_point(t, "", b)
    no_n = v5_point(t, "")
    :ok = Qdrant.upsert_points(col, [b_point, no_n, r3a_point(t, a)])
    path = Base.encode64(t.path)

    assert {:ok, 2} = Qdrant.count_by_note(col, t.user_id, t.vault_id, a, path)
    assert :ok = Qdrant.delete_by_note(col, t.user_id, t.vault_id, a, path)
    assert left(col, t) == [b_point.id]
  end

  # Strict mode 400s a filter on `n` while the collection has no `n` index:
  # the per-note filters fall back to the path alone. `ensure_collection/2`
  # rebuilding the index replaces the cached "no", so the very next filter
  # takes the `n` arm (no stale-"no" minute after boot).
  test "without the n index: path alone, no 400; ensure_collection turns the n arm on",
       %{col: col} do
    {:ok, %{status: 200}} = Req.delete("#{qdrant_url()}/collections/#{col}/index/n?wait=true")
    # Restore the index even if an assertion below fails (`on_exit` runs in
    # another process, so it needs the URL override again). The collection
    # is this module's own and is dropped at module exit regardless.
    url = qdrant_url()

    on_exit(fn ->
      ServiceConfig.put_override(:qdrant_url, url)
      Qdrant.ensure_collection(col, @dims)
    end)

    refute Qdrant.n_filterable?(col)

    t = tenant()
    id = Ecto.UUID.generate()
    r3a = r3a_point(t, id)
    :ok = Qdrant.upsert_points(col, [v5_point(t, "", id), r3a])
    path = Base.encode64(t.path)

    assert {:ok, 1} = Qdrant.count_by_note(col, t.user_id, t.vault_id, id, path)
    assert :ok = Qdrant.delete_by_note(col, t.user_id, t.vault_id, id, path)
    assert left(col, t) == [r3a.id]

    assert :ok = Qdrant.ensure_collection(col, @dims)
    assert {:ok, 1} = Qdrant.count_by_note(col, t.user_id, t.vault_id, id, path)
    assert :ok = Qdrant.delete_by_note(col, t.user_id, t.vault_id, id, path)
    assert left(col, t) == []
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

    assert {:ok, 2} =
             Qdrant.count_by_note(
               col,
               t.user_id,
               t.vault_id,
               Ecto.UUID.generate(),
               Base.encode64(new_path)
             )

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

  # `n` / `d` are plaintext and the user-key ids start at 64 for everyone, so
  # the tenant clause alone keeps two users' equal numbers apart.
  test "cross tenant: plaintext n / d at the same key id never cross", %{col: col} do
    a = tenant()
    b = tenant()

    :ok =
      Qdrant.upsert_points(col, [
        v5_point(a, "rating: 4\nlaunch: 2026-11-01\n"),
        v5_point(b, "rating: 4\nlaunch: 2026-11-01\n")
      ])

    ub = %{key: "u", match: %{value: FilterId.uuid(b.user_id)}}
    n = Qdrant.attr_filter(key_id("rating"), {:n, gte: 4})

    d =
      Qdrant.attr_filter(key_id("launch"), {:d, gte: DateTime.to_unix(~U[2026-11-01 00:00:00Z])})

    # The module shares one collection, so count per tenant, never globally.
    ua = %{key: "u", match: %{value: FilterId.uuid(a.user_id)}}
    assert count(col, %{must: [ua, n]}) == 1
    assert count(col, %{must: [ub, n]}) == 1
    assert count(col, %{must: [ub, d]}) == 1

    gone = tenant()
    ug = %{key: "u", match: %{value: FilterId.uuid(gone.user_id)}}
    assert count(col, %{must: [ug, n]}) == 0
    assert count(col, %{must: [ug, d]}) == 0
  end

  # H1 against the real payload: each named field's `fields` condition
  # matches the point that carries it and not the one that does not.
  test "named-field filters match what v5 writes", %{col: col} do
    t = tenant()

    yaml =
      "status: draft\nauthor: alice\nreviewed_by: bob\nproject: apollo\nsource: [https://a]\n" <>
        "created: 2026-03-01T09:00:00Z\nupdated: 2026-04-01T10:00:00Z\nreviewed: 2026-04-02T00:00:00Z\n" <>
        "expires: 2026-12-01\ndue: 2026-11-01\npriority: 2\n"

    :ok = Qdrant.upsert_points(col, [v5_point(t, yaml), v5_point(t, "")])
    u = %{key: "u", match: %{value: FilterId.uuid(t.user_id)}}

    hits = fn filter ->
      {:ok, [c]} = Engram.Search.FieldFilters.to_conditions(t.user_id, t.fk, [filter])
      count(col, %{must: [u, c]})
    end

    for {key, op, value} <- [
          {"status", "eq", "Draft"},
          {"author", "eq", "alice"},
          {"reviewed_by", "eq", "bob"},
          {"project", "eq", "apollo"},
          {"source", "eq", "https://a"},
          {"resource", "in", ["https://a", "x"]},
          {"created", "after", "2026-03-01"},
          {"date", "after", "2026-02-28"},
          {"updated", "eq", "2026-04-01"},
          {"modified", "gte", "2026-04-01T10:00:00Z"},
          {"reviewed", "lte", "2026-04-02"},
          {"expires", "eq", "2026-12-01"},
          {"stale_after", "after", "2026-11-30"},
          {"due", "before", "2026-11-02"},
          {"priority", "gte", 2}
        ] do
      assert hits.(%{"key" => key, "op" => op, "value" => value}) == 1, "#{key} #{op}"
    end

    # The default status matches the note that sets none (stored as no key).
    assert hits.(%{"key" => "status", "value" => "stable"}) == 1
    assert hits.(%{"key" => "due", "op" => "after", "value" => "2026-11-02"}) == 0
  end

  # YAML reads `status: 2` as a number, `reviewed_by: true` as a boolean and
  # `project: 2026-01-01` as a date-shaped string: a named exact field holds
  # each as its text, so the text filter finds them in a real Qdrant.
  test "numeric, boolean and date-shaped named values match as text", %{col: col} do
    t = tenant()

    yaml =
      "status: 2\nauthor: 42\nreviewed_by: true\nproject: 2026-01-01\n" <>
        "source: [2024, https://a]\n"

    :ok = Qdrant.upsert_points(col, [v5_point(t, yaml), v5_point(t, "status: 3\n")])
    u = %{key: "u", match: %{value: FilterId.uuid(t.user_id)}}

    hits = fn filter ->
      {:ok, [c]} = Engram.Search.FieldFilters.to_conditions(t.user_id, t.fk, [filter])
      count(col, %{must: [u, c]})
    end

    for {key, value} <- [
          {"status", "2"},
          {"status", 2},
          {"author", "42"},
          {"reviewed_by", true},
          {"reviewed_by", "true"},
          {"project", "2026-01-01"},
          {"source", "2024"}
        ] do
      assert hits.(%{"key" => key, "value" => value}) == 1, "#{key} #{inspect(value)}"
    end
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
