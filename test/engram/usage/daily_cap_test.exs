defmodule Engram.Usage.DailyCapTest do
  use Engram.DataCase, async: false
  alias Engram.Usage.DailyCap

  # user_id is a UUID string. These buckets are a system table (no FK enforcement
  # blocker for the test since on_delete is delete_all and we never create the
  # user row — but if the FK rejects orphan user_ids, insert a user via the
  # existing test factory and use its id instead).
  defp uid, do: Ecto.UUID.generate()

  test "first spend creates the bucket near full and allows" do
    assert {:allow, left} = DailyCap.spend(uid(), "inapp_search", 10, 10 / 86_400)
    assert_in_delta left, 9.0, 0.01
  end

  test "spending past capacity denies" do
    u = uid()
    for _ <- 1..10, do: DailyCap.spend(u, "inapp_search", 10, 0.0)
    assert {:deny, _retry} = DailyCap.spend(u, "inapp_search", 10, 0.0)
  end

  test "tokens refill over elapsed time" do
    u = uid()
    for _ <- 1..10, do: DailyCap.spend(u, "inapp_search", 10, 0.0)
    # 1 token/sec refill, simulate by backdating last_refill_at 5s
    {:ok, u_bin} = Ecto.UUID.dump(u)

    Engram.Repo.query!(
      "UPDATE usage_buckets SET last_refill_at = now() - interval '5 seconds' WHERE user_id = $1::uuid",
      [u_bin]
    )

    assert {:allow, _} = DailyCap.spend(u, "inapp_search", 10, 1.0)
  end
end
