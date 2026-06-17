defmodule Engram.SeedsTest do
  use Engram.DataCase, async: true

  alias Engram.Billing.{LimitKeys, Plan}
  alias Engram.Repo

  @seeds_path "priv/repo/seeds.exs"

  setup do
    Repo.delete_all(Plan)
    :ok
  end

  defp run_seeds, do: Code.eval_file(@seeds_path)

  describe "seeds.exs" do
    test "creates exactly three plans named free / starter / pro" do
      run_seeds()

      names = Plan |> Repo.all() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ~w(free pro starter)
    end

    test "every plan has all 19 catalog keys with catalog defaults" do
      run_seeds()

      for tier <- LimitKeys.tiers() do
        plan = Repo.get_by!(Plan, name: to_string(tier))

        for key <- LimitKeys.all() do
          assert Map.has_key?(plan.limits, to_string(key)),
                 "plan #{tier} missing key #{key}"

          assert plan.limits[to_string(key)] == LimitKeys.default_for(key, tier),
                 "plan #{tier} key #{key} drifted from catalog default"
        end
      end
    end

    test "re-running seeds is idempotent — no duplicate rows, count stays at 3" do
      run_seeds()
      assert Repo.aggregate(Plan, :count) == 3

      run_seeds()
      assert Repo.aggregate(Plan, :count) == 3
    end

    test "re-running seeds restores limits when a plan's matrix is mutated" do
      run_seeds()
      free = Repo.get_by!(Plan, name: "free")

      free
      |> Ecto.Changeset.change(limits: Map.put(free.limits, "notes_cap", 99_999))
      |> Repo.update!()

      assert Repo.get_by!(Plan, name: "free").limits["notes_cap"] == 99_999

      run_seeds()

      restored = Repo.get_by!(Plan, name: "free").limits["notes_cap"]
      assert restored == LimitKeys.default_for(:notes_cap, :free)
    end
  end
end
