defmodule Engram.Legal.SeederTest do
  use Engram.DataCase, async: true
  import Ecto.Query
  alias Engram.Legal
  alias Engram.Legal.Seeder

  test "seed/0 inserts a row per manifest entry with the manifest hash + seed meta" do
    assert :ok = Seeder.seed()
    # v1 terms row exists with the manifest hash and is effective now (material).
    assert Legal.required_floor("terms_of_service") == "2026-05-19"

    assert Legal.hash_for("terms_of_service", "2026-05-19") ==
             "372e3b55589eaa8e77311beefacc3818f0691cc378a06f0a12f243323769691c"

    # No privacy floor: 2026-06-20 is the baseline (no effective date, never
    # gates) and 2026-10-12 (identified analytics) is notice-only.
    assert Legal.required_floor("privacy_policy") == nil

    assert Legal.hash_for("privacy_policy", "2026-10-12") ==
             "f4d33b4d28e376d0180fac57825ae9e37b79d3458c4123f22a41afd8002ce067"

    # seed→verify round-trips cleanly when the DB matches the manifest.
    assert :ok = Seeder.verify()
  end

  test "seed/0 is idempotent" do
    assert :ok = Seeder.seed()
    assert :ok = Seeder.seed()
    rows = Engram.Repo.all(Engram.Legal.TermsVersion, skip_tenant_check: true)
    assert length(rows) == 4
  end

  # A date or materiality change after the email went out told users the
  # wrong thing ("no action needed", or the old date), so they are told again.
  test "seed/0 clears the sent stamps when effective_date or material changed" do
    :ok = Seeder.seed()
    sent = ~U[2026-10-01 12:00:00.000000Z]
    rows = from(v in Legal.TermsVersion, where: v.document == "privacy_policy")

    stamp = fn version, extra ->
      rows
      |> where(version: ^version)
      |> Repo.update_all([set: [notified_at: sent, reminded_at: sent] ++ extra],
        skip_tenant_check: true
      )
    end

    # 2026-10-12 as announced with an older date; 2026-06-20 unchanged.
    stamp.("2026-10-12", effective_date: ~D[2026-11-01])
    stamp.("2026-06-20", [])

    :ok = Seeder.seed()

    stamps =
      Repo.all(select(rows, [v], {v.version, v.notified_at, v.reminded_at}),
        skip_tenant_check: true
      )

    assert {"2026-10-12", nil, nil} in stamps
    assert {"2026-06-20", sent, sent} in stamps
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

  describe "notice_violations" do
    test "the shipped version meta gives every material change 30 days' notice" do
      assert Seeder.notice_violations() == []
    end

    test "flags a material change after the first with no or short notice" do
      meta = %{
        "terms_of_service" => %{
          "2026-05-19" => %{material: true, effective_date: nil},
          "2026-07-01" => %{material: true, effective_date: nil},
          "2026-08-01" => %{material: true, effective_date: ~D[2026-08-20]},
          "2026-09-01" => %{material: true, effective_date: ~D[2026-10-01]},
          "2026-09-02" => %{material: false, effective_date: nil}
        }
      }

      assert Seeder.notice_violations(meta) == [
               {"terms_of_service", "2026-07-01"},
               {"terms_of_service", "2026-08-01"}
             ]
    end
  end
end
