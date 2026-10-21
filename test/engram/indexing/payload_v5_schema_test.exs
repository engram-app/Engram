defmodule Engram.Indexing.PayloadV5SchemaTest do
  use ExUnit.Case, async: true

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
      p = PayloadV5.build(note(%{mtime: 1_760_000_000.9}), FlatFields.empty())
      assert {p["up"], p["us"]} == {1_760_000_000, 1}

      p = PayloadV5.build(note(), FlatFields.empty())
      assert {p["up"], p["us"]} == {DateTime.to_unix(~U[2026-01-02 00:00:00Z]), 2}
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
