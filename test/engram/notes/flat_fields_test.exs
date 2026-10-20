defmodule Engram.Notes.FlatFieldsTest do
  use ExUnit.Case, async: true

  alias Engram.Notes.FlatFields
  alias Engram.Vector.FilterId

  @fk :crypto.strong_rand_bytes(32)

  defp extract(yaml), do: FlatFields.extract("---\n" <> yaml <> "---\nbody\n", @fk)
  defp v(value), do: FilterId.value_hmac(@fk, value)
  defp unix(dt), do: DateTime.to_unix(dt)

  test "no frontmatter gives the empty result" do
    assert FlatFields.extract("just a body\n", @fk) == FlatFields.empty()
    assert FlatFields.extract(nil, @fk) == FlatFields.empty()
  end

  test "the flat exact keys store a plaintext and its HMAC" do
    got =
      extract("""
      status: Draft
      author: alice
      reviewed_by: bob
      project: apollo
      source: [https://a, https://b]
      """)

    assert got.status == "Draft" and got.status_hmac == v("draft")
    assert got.author == "alice" and got.author_hmac == v("alice")
    assert got.reviewed_by == "bob" and got.rev_by_hmac == v("bob")
    assert got.project == "apollo" and got.proj_hmac == v("apollo")
    assert got.source == ["https://a", "https://b"]
    assert got.src_hmac == [v("https://a"), v("https://b")]
  end

  test "a single source string is a one-element list" do
    assert extract("source: https://a\n").source == ["https://a"]
  end

  test "the flat key wins over its nested alias" do
    got =
      extract("""
      author: alice
      reviewed_by: bob
      source: https://flat
      resource: https://alias
      reviewed: 2026-02-01
      expires: 2026-03-01
      updated: 2026-04-01
      generated:
        by: "agent:x"
        at: 2026-05-01T00:00:00Z
      verified:
        - by: carol
          at: 2026-06-01T00:00:00Z
      stale_after: 2026-07-01T00:00:00Z
      """)

    assert got.author == "alice"
    assert got.reviewed_by == "bob"
    assert got.source == ["https://flat"]
    assert got.fm_reviewed == unix(~U[2026-02-01 00:00:00Z])
    assert got.fm_expires == unix(~U[2026-03-01 00:00:00Z])
    assert got.fm_updated == unix(~U[2026-04-01 00:00:00Z])
  end

  test "the nested aliases fill an absent flat key" do
    got =
      extract("""
      generated:
        by: "agent:x"
        at: 2026-05-01T00:00:00Z
      verified:
        - by: carol
          at: 2026-06-01T00:00:00Z
        - by: dave
          at: 2026-06-03T00:00:00Z
      sources: [https://s1, https://s2]
      stale_after: 2026-07-01T00:00:00Z
      """)

    assert got.author == "agent:x"
    assert got.fm_updated == unix(~U[2026-05-01 00:00:00Z])
    assert got.reviewed_by == "dave"
    assert got.fm_reviewed == unix(~U[2026-06-03 00:00:00Z])
    assert got.source == ["https://s1", "https://s2"]
    assert got.fm_expires == unix(~U[2026-07-01 00:00:00Z])
  end

  test "resource fills source when neither source nor sources is set" do
    assert extract("resource: https://r\n").source == ["https://r"]
  end

  test "date rules: a bare flat date is midnight UTC, a bare nested alias date is rejected" do
    assert extract("due: 2026-11-01\n").fm_due == unix(~U[2026-11-01 00:00:00Z])
    assert extract("stale_after: 2026-11-01\n").fm_expires == nil
    assert extract("generated:\n  at: 2026-11-01\n").fm_updated == nil
    assert extract("verified:\n  - at: 2026-11-01\n").fm_reviewed == nil
    assert extract("due: soon\n").fm_due == nil
  end

  test "updated aliases: updated > generated.at > timestamp > modified" do
    assert extract("modified: 2026-01-02\ntimestamp: 2026-01-03\n").fm_updated ==
             unix(~U[2026-01-03 00:00:00Z])

    assert extract("modified: 2026-01-02\n").fm_updated == unix(~U[2026-01-02 00:00:00Z])

    assert extract("created: 2026-01-05\ndate: 2026-01-06\n").fm_created ==
             unix(~U[2026-01-05 00:00:00Z])

    assert extract("date: 2026-01-06\n").fm_created == unix(~U[2026-01-06 00:00:00Z])
  end

  test "priority is a float; a non-number is dropped" do
    assert extract("priority: 2\n").fm_priority == 2.0
    assert extract("priority: 1.5\n").fm_priority == 1.5
    assert extract("priority: high\n").fm_priority == nil
  end

  test "unknown status values are kept" do
    assert extract("status: weird\n").status == "weird"
  end

  test "other keys go to the long tail" do
    got = extract("mood: calm\nstatus: draft\n")
    assert got.attrs == [%{k: FilterId.key_hmac(@fk, "mood"), v: v("calm")}]
  end
end
