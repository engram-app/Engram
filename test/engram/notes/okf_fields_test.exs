defmodule Engram.Notes.OkfFieldsTest do
  use ExUnit.Case, async: true

  alias Engram.Notes.OkfFields

  @empty %{type: nil, description: nil, resource: nil, fm_timestamp: nil, fm_created: nil}

  test "extracts all OKF fields from a full frontmatter block" do
    content = """
    ---
    type: Playbook
    description: Steps to triage a freshness alert.
    resource: https://example.com/dash
    timestamp: 2026-05-28T14:30:00Z
    created: 2026-05-01
    ---
    body
    """

    assert OkfFields.extract(content) == %{
             type: "Playbook",
             description: "Steps to triage a freshness alert.",
             resource: "https://example.com/dash",
             fm_timestamp: ~U[2026-05-28 14:30:00Z],
             fm_created: ~U[2026-05-01 00:00:00Z]
           }
  end

  test "returns all-nil for content without frontmatter" do
    assert OkfFields.extract("just a body\n") == @empty
  end

  test "returns all-nil for malformed YAML" do
    assert OkfFields.extract("---\n: : :\n---\nbody\n") == @empty
  end

  test "timestamp alias priority: timestamp > modified > updated" do
    ts = fn block -> OkfFields.extract("---\n#{block}---\nx\n").fm_timestamp end

    assert ts.("timestamp: 2026-01-01\nmodified: 2026-02-02\nupdated: 2026-03-03\n") ==
             ~U[2026-01-01 00:00:00Z]

    assert ts.("modified: 2026-02-02\nupdated: 2026-03-03\n") == ~U[2026-02-02 00:00:00Z]
    assert ts.("updated: 2026-03-03\n") == ~U[2026-03-03 00:00:00Z]
  end

  test "created alias priority: created > date" do
    cr = fn block -> OkfFields.extract("---\n#{block}---\nx\n").fm_created end
    assert cr.("created: 2026-01-05\ndate: 2026-01-06\n") == ~U[2026-01-05 00:00:00Z]
    assert cr.("date: 2026-01-06\n") == ~U[2026-01-06 00:00:00Z]
  end

  test "bare date parses as UTC midnight; invalid date is nil" do
    assert OkfFields.extract("---\ntimestamp: 2026-06-12\n---\nx\n").fm_timestamp ==
             ~U[2026-06-12 00:00:00Z]

    assert OkfFields.extract("---\ntimestamp: not-a-date\n---\nx\n").fm_timestamp == nil
  end

  test "non-string type/description/resource values are nil" do
    assert OkfFields.extract("---\ntype: 42\ndescription: [a, b]\nresource: true\n---\nx\n") ==
             @empty
  end

  test "extracts a good OKF key even when a sibling frontmatter key is degraded" do
    # Resilience improvement (Task 5): a single unencodable sibling key
    # (nested non-binary key) no longer forces the whole block to @empty.
    # The good `created` key still populates fm_created.
    content = "---\ncreated: 2026-01-05\nbadkey: {[a, b]: 1}\n---\nbody\n"
    assert OkfFields.extract(content).fm_created == ~U[2026-01-05 00:00:00Z]
  end

  test "normalize_type is NFKC + lowercase" do
    assert OkfFields.normalize_type("Playbook") == "playbook"
    assert OkfFields.normalize_type("ＮＯＴＥ") == "note"
  end
end
