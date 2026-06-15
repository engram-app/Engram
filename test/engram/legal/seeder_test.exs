defmodule Engram.Legal.SeederTest do
  use Engram.DataCase, async: false
  alias Engram.Legal
  alias Engram.Legal.Seeder

  test "seed/0 inserts a row per manifest entry with the manifest hash + seed meta" do
    assert :ok = Seeder.seed()
    # v1 terms row exists with the manifest hash and is effective now (material).
    assert Legal.required_floor("terms_of_service") == "2026-05-19"

    assert Legal.hash_for("terms_of_service", "2026-05-19") ==
             "372e3b55589eaa8e77311beefacc3818f0691cc378a06f0a12f243323769691c"

    assert Legal.required_floor("privacy_policy") == "2026-05-19"
    # seed→verify round-trips cleanly when the DB matches the manifest.
    assert :ok = Seeder.verify()
  end

  test "seed/0 is idempotent" do
    assert :ok = Seeder.seed()
    assert :ok = Seeder.seed()
    rows = Engram.Repo.all(Engram.Legal.TermsVersion, skip_tenant_check: true)
    assert length(rows) == 2
  end

  test "verify/0 raises when a DB row's hash diverges from the manifest" do
    Seeder.seed()

    Engram.Repo.update_all(
      Engram.Legal.TermsVersion,
      [set: [content_hash: "tampered"]],
      skip_tenant_check: true
    )

    assert_raise RuntimeError, ~r/hash drift/i, fn -> Seeder.verify() end
  end
end
