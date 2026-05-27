defmodule Engram.Legal.TermsVersionTest do
  use Engram.DataCase, async: true
  alias Engram.Legal.TermsVersion

  test "changeset requires document, version, content_hash" do
    cs = TermsVersion.changeset(%TermsVersion{}, %{})
    refute cs.valid?
    assert %{document: _, version: _, content_hash: _} = errors_on(cs)
  end

  test "changeset accepts a full row" do
    cs =
      TermsVersion.changeset(%TermsVersion{}, %{
        document: "terms_of_service",
        version: "2026-05-19",
        content_hash: "abc",
        material: true,
        effective_date: nil,
        changelog: "Initial version."
      })

    assert cs.valid?
  end

  test "changeset rejects an unknown document" do
    cs =
      TermsVersion.changeset(%TermsVersion{}, %{
        document: "cookie_policy",
        version: "2026-05-19",
        content_hash: "abc"
      })

    refute cs.valid?
    assert %{document: _} = errors_on(cs)
  end

  test "changeset rejects a malformed version" do
    cs =
      TermsVersion.changeset(%TermsVersion{}, %{
        document: "terms_of_service",
        version: "v1.2.3",
        content_hash: "abc"
      })

    refute cs.valid?
    assert %{version: _} = errors_on(cs)
  end
end
