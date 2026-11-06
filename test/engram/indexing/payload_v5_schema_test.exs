defmodule Engram.Indexing.PayloadV5SchemaTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Engram.Indexing.PayloadV5
  alias Engram.Notes.FlatFields
  alias Engram.Notes.Note
  alias Engram.Vector.FilterId
  alias Engram.Vector.PayloadKeys

  @fk :crypto.strong_rand_bytes(32)
  @id ~r/^[0-9a-f]{32}$/
  @allowed MapSet.new(PayloadKeys.logical_names(), &PayloadKeys.short/1)
  @always ~w(u v p f up cr)

  # `ctime` arrives with #2082; until then it rides as a plain map key, which is
  # how PayloadV5 reads it (`Map.get/2`).
  defp note(attrs \\ %{}) do
    struct(
      %Note{
        id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        vault_id: Ecto.UUID.generate(),
        path_hmac: :crypto.strong_rand_bytes(32),
        folder_hmac: :crypto.strong_rand_bytes(32),
        tags_hmac: [],
        mtime: nil,
        created_at: ~U[2026-01-01 00:00:00.000000Z],
        updated_at: ~U[2026-01-02 00:00:00.000000Z]
      },
      attrs
    )
    |> Map.merge(Map.take(attrs, [:ctime]))
  end

  defp payload(note, yaml) do
    flat = FlatFields.extract("---\n" <> yaml <> "---\nbody\n", @fk)
    # Dictionary ids as `FrontmatterKeys.resolve/3` would hand them out.
    ids = flat.names |> Map.keys() |> Enum.sort() |> Enum.with_index(64) |> Map.new()
    PayloadV5.build(note, FlatFields.put_key_ids(flat, ids))
  end

  @full """
  status: draft
  author: alice
  reviewed_by: bob
  source: [https://a]
  project: apollo
  updated: 2026-04-01T10:00:00Z
  created: 2026-03-01T09:00:00Z
  reviewed: 2026-04-02T00:00:00Z
  expires: 2026-12-01
  due: 2026-11-01
  priority: 2
  mood: calm
  rating: 4.5
  launch: 2026-10-01
  """

  test "a note with every field stores exactly the allowed short keys" do
    n = note(%{type_hmac: :crypto.strong_rand_bytes(32), tags_hmac: [<<1::256>>]})
    p = payload(n, @full)

    # Every key but the two default source flags (fm).
    assert MapSet.new(Map.keys(p)) == MapSet.difference(@allowed, MapSet.new(~w(us cs)))
  end

  test "fa: one entry per user value, `h` exact, `n` / `d` plaintext" do
    p = payload(note(), "mood: calm\nrating: 4.5\nlaunch: 2026-10-01\ntags2: [x, y]\n")
    kinds = p["fa"] |> Enum.map(&(Map.keys(&1) -- ["k"])) |> Enum.sort()
    assert kinds == [["d"], ["h"], ["h"], ["h"], ["n"]]
    assert Enum.find(p["fa"], &Map.has_key?(&1, "n"))["n"] == 4.5
  end

  test "a key without a dictionary id (past the cap) is left out of fa" do
    flat = FlatFields.extract("---\nmood: calm\n---\nbody\n", @fk)
    refute Map.has_key?(PayloadV5.build(note(), flat), "fa")
  end

  test "the fallback sources store their flags, and no key outside the set" do
    p = PayloadV5.build(note(%{mtime: 1_760_000_000.7}), FlatFields.empty())
    assert MapSet.subset?(MapSet.new(Map.keys(p)), @allowed)
    assert p["us"] == 1 and p["cs"] == 2

    for banned <- ~w(note_id text title heading_path aad_version user_id vault_id),
        do: refute(Map.has_key?(p, banned))
  end

  test "a note with no frontmatter stores only the always-present keys plus src flags" do
    p = PayloadV5.build(note(), FlatFields.empty())
    assert MapSet.new(Map.keys(p)) == MapSet.new(@always ++ ~w(us cs))
    refute Enum.any?(Map.values(p), &(&1 in [nil, []]))
  end

  test "every id is a 128-bit hex filter id" do
    n = note(%{type_hmac: :crypto.strong_rand_bytes(32), tags_hmac: [<<1::256>>, <<2::256>>]})
    p = payload(n, @full)

    for key <- ~w(u v p f y s a r j), do: assert(p[key] =~ @id, key)
    for list <- ~w(g o), id <- p[list], do: assert(id =~ @id)
    for %{"k" => k} <- p["fa"], do: assert(is_integer(k) and k >= 64)
    for %{"h" => h} <- p["fa"], do: assert(h =~ @id)
    assert p["u"] == FilterId.uuid(n.user_id)
    assert p["p"] == FilterId.from_hmac(n.path_hmac)
  end

  test "status stable is the default and stores no s" do
    refute Map.has_key?(payload(note(), "status: stable\n"), "s")
    refute Map.has_key?(payload(note(), "status: Stable\n"), "s")
    assert Map.has_key?(payload(note(), "status: draft\n"), "s")
  end

  test "frontmatter dates store no src flags" do
    p = payload(note(), "updated: 2026-04-01T10:00:00Z\ncreated: 2026-03-01\n")
    refute Map.has_key?(p, "us")
    refute Map.has_key?(p, "cs")
    assert p["up"] == DateTime.to_unix(~U[2026-04-01 10:00:00Z])
    assert p["cr"] == DateTime.to_unix(~U[2026-03-01 00:00:00Z])
  end

  test "date-only fields are day numbers, the others unix seconds" do
    p = payload(note(), "due: 2026-11-01\nexpires: 2026-11-02\nreviewed: 2026-11-03T12:00:00Z\n")
    assert p["du"] == 20_758
    assert p["ex"] == 20_759
    assert p["rd"] == DateTime.to_unix(~U[2026-11-03 12:00:00Z])
  end

  describe "date fallback" do
    test "mtime is the file time, else updated_at is the server time" do
      # 1_760_000_000 is 2025-10-09 08:53:20Z: rounded up to 09:00:00Z.
      p = PayloadV5.build(note(%{mtime: 1_760_000_000.9}), FlatFields.empty())
      assert {p["up"], p["us"]} == {DateTime.to_unix(~U[2025-10-09 09:00:00Z]), 1}

      p = PayloadV5.build(note(), FlatFields.empty())
      assert {p["up"], p["us"]} == {DateTime.to_unix(~U[2026-01-02 00:00:00Z]), 2}
    end

    defp up_of(attrs), do: PayloadV5.build(note(attrs), FlatFields.empty())["up"]
    defp unix(dt), do: DateTime.to_unix(dt)

    test "a fallback mtime rounds UP to the next full hour" do
      assert up_of(%{mtime: unix(~U[2026-04-01 14:20:05Z]) * 1.0}) ==
               unix(~U[2026-04-01 15:00:00Z])

      # A fraction of a second past the hour is past the hour.
      assert up_of(%{mtime: unix(~U[2026-04-01 14:00:00Z]) + 0.5}) ==
               unix(~U[2026-04-01 15:00:00Z])
    end

    test "a fallback exactly on the hour stays as it is" do
      assert up_of(%{mtime: unix(~U[2026-04-01 14:00:00Z]) * 1.0}) ==
               unix(~U[2026-04-01 14:00:00Z])

      assert up_of(%{mtime: nil, updated_at: ~U[2026-04-01 14:00:00.000000Z]}) ==
               unix(~U[2026-04-01 14:00:00Z])
    end

    test "the updated_at fallback rounds up the same way" do
      p =
        PayloadV5.build(note(%{updated_at: ~U[2026-04-01 14:20:05.123456Z]}), FlatFields.empty())

      assert {p["up"], p["us"]} == {unix(~U[2026-04-01 15:00:00Z]), 2}
    end

    # Main's formula before the stored dates (#2434), verbatim: the payload
    # hash of a seconds-unit note must not move. Only millisecond values may.
    defp main_up(t, _updated_at) when is_number(t) and t > 0, do: {ceil(t / 3600) * 3600, 1}
    defp main_up(_t, updated_at), do: {ceil(DateTime.to_unix(updated_at) / 3600) * 3600, 2}
    defp main_cr(t, _created_at) when is_number(t) and t > 0, do: {trunc(t), 1}
    defp main_cr(_t, created_at), do: {DateTime.to_unix(created_at), 2}

    defp same_as_main!(t) do
      n = note(%{mtime: t, ctime: t})
      p = PayloadV5.build(n, FlatFields.empty())
      assert {p["up"], p["us"]} == main_up(t, n.updated_at), inspect(t)
      assert {p["cr"], p["cs"]} == main_cr(t, n.created_at), inspect(t)
    end

    property "seconds-unit file times give main's up and cr exactly" do
      hour = 3600

      check all(
              base <- integer(1..99_999_999_999),
              frac <- float(min: 0.0, max: 0.999999999),
              near <- member_of([0, 1, -1]),
              max_runs: 2_000
            ) do
        t = base + frac
        if t < 1.0e11, do: same_as_main!(t)
        # On and around exact hours, plus a sub-microsecond past one.
        h = div(base, hour) * hour + near
        if h > 0, do: same_as_main!(h * 1.0)
      end
    end

    test "edge values: one ulp past an hour, negatives and 0 are main's" do
      for t <- [
            1_819_922_400.0000002,
            1_776_072_500.9999995,
            3600.0,
            0.5,
            -1.0,
            -86_400.5,
            0,
            0.0,
            nil
          ] do
        same_as_main!(t)
      end
    end

    test "only a millisecond-unit file time differs from main" do
      n = note(%{mtime: 1_793_442_859_572.0, ctime: 1_793_442_859_572.0})
      p = PayloadV5.build(n, FlatFields.empty())
      assert p["cr"] == 1_793_442_859
      assert p["up"] == ceil(1_793_442_859.572 / 3600) * 3600
      refute {p["up"], p["us"]} == main_up(1_793_442_859_572.0, n.updated_at)
    end

    test "a nil or 0 mtime falls to updated_at, rounded" do
      for mtime <- [nil, 0, 0.0] do
        p =
          PayloadV5.build(
            note(%{mtime: mtime, updated_at: ~U[2026-04-01 14:20:05.000000Z]}),
            FlatFields.empty()
          )

        assert {p["up"], p["us"]} == {unix(~U[2026-04-01 15:00:00Z]), 2}, inspect(mtime)
      end
    end

    test "a frontmatter updated stays exact, unrounded" do
      p = payload(note(%{mtime: 1_760_000_000.0}), "updated: 2026-04-01T14:20:05Z\n")
      assert p["up"] == unix(~U[2026-04-01 14:20:05Z])
      refute Map.has_key?(p, "us")
    end

    test "two passes within the same hour give an equal payload hash" do
      n = note()
      early = %{n | mtime: unix(~U[2026-04-01 14:00:01Z]) * 1.0}
      late = %{n | mtime: unix(~U[2026-04-01 14:59:59Z]) * 1.0}
      next = %{n | mtime: unix(~U[2026-04-01 15:00:01Z]) * 1.0}
      hash = &Engram.Indexing.note_payload_hash(PayloadV5.build(&1, FlatFields.empty()))

      assert hash.(early) == hash.(late)
      refute hash.(late) == hash.(next)

      at = &%{n | updated_at: &1}

      assert hash.(at.(~U[2026-04-01 14:00:01.000000Z])) ==
               hash.(at.(~U[2026-04-01 14:59:59.000000Z]))
    end

    test "a frontmatter updated wins over mtime" do
      p = payload(note(%{mtime: 1_760_000_000.0}), "updated: 2026-04-01\n")
      assert p["up"] == DateTime.to_unix(~U[2026-04-01 00:00:00Z])
      refute Map.has_key?(p, "us")
    end

    test "ctime is the file creation time, else created_at" do
      p = PayloadV5.build(note(%{ctime: 1_700_000_000.2}), FlatFields.empty())
      assert {p["cr"], p["cs"]} == {1_700_000_000, 1}

      p = PayloadV5.build(note(), FlatFields.empty())
      assert {p["cr"], p["cs"]} == {DateTime.to_unix(~U[2026-01-01 00:00:00Z]), 2}
    end

    test "a later frontmatter created wins with src fm" do
      p = payload(note(%{ctime: 1_700_000_000.0}), "created: 2026-05-01\n")
      assert p["cr"] == DateTime.to_unix(~U[2026-05-01 00:00:00Z])
      refute Map.has_key?(p, "cs")
    end
  end

  test "a root note stores no folder id" do
    refute Map.has_key?(PayloadV5.build(note(%{folder_hmac: nil}), FlatFields.empty()), "f")
  end

  describe "size, excluding vectors" do
    test "a typical note with frontmatter dates is under 200 B" do
      p = payload(note(), "updated: 2026-04-01T10:00:00Z\ncreated: 2026-03-01T09:00:00Z\n")
      assert byte_size(Jason.encode!(p)) < 200, "#{byte_size(Jason.encode!(p))} B"
    end

    # Known over by the two source flags: 203 B (see the PR). Pinned so a
    # change in either direction is a decision, not drift.
    test "a typical plugin note dated by file times is 203 B" do
      n = note(%{mtime: 1_760_000_000.0, ctime: 1_750_000_000.0})
      assert byte_size(Jason.encode!(PayloadV5.build(n, FlatFields.empty()))) == 203
    end
  end
end
