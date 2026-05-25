defmodule Engram.UsageMetersTest do
  use Engram.DataCase, async: true

  alias Engram.UsageMeters

  describe "lifetime_embed_tokens/1" do
    test "returns 0 for users without a meter row yet" do
      user = insert(:user)
      assert UsageMeters.lifetime_embed_tokens(user.id) == 0
    end

    test "returns the stored count after add_embed_tokens" do
      user = insert(:user)
      UsageMeters.add_embed_tokens(user.id, 1500)
      assert UsageMeters.lifetime_embed_tokens(user.id) == 1500
    end
  end

  describe "add_embed_tokens/2" do
    test "lazy-inits a row on first call" do
      user = insert(:user)
      assert UsageMeters.add_embed_tokens(user.id, 100) == 100
    end

    test "monotonically accumulates across calls" do
      user = insert(:user)
      UsageMeters.add_embed_tokens(user.id, 100)
      UsageMeters.add_embed_tokens(user.id, 250)
      UsageMeters.add_embed_tokens(user.id, 50)
      assert UsageMeters.lifetime_embed_tokens(user.id) == 400
    end

    test "increments are isolated per user" do
      a = insert(:user)
      b = insert(:user)
      UsageMeters.add_embed_tokens(a.id, 500)
      UsageMeters.add_embed_tokens(b.id, 700)
      assert UsageMeters.lifetime_embed_tokens(a.id) == 500
      assert UsageMeters.lifetime_embed_tokens(b.id) == 700
    end

    test "concurrent increments never lose updates" do
      user = insert(:user)

      1..20
      |> Task.async_stream(fn _ -> UsageMeters.add_embed_tokens(user.id, 10) end,
        max_concurrency: 10
      )
      |> Stream.run()

      assert UsageMeters.lifetime_embed_tokens(user.id) == 200
    end
  end

  describe "estimate_tokens/1" do
    test "returns ceil(bytes/4) for ASCII content" do
      assert UsageMeters.estimate_tokens("hello world") == 3
      assert UsageMeters.estimate_tokens("a") == 1
      assert UsageMeters.estimate_tokens("") == 0
    end

    test "rounds up so the cap remains conservative" do
      # 5 bytes / 4 = 1.25 → 2 tokens (over-counts slightly, never under)
      assert UsageMeters.estimate_tokens("abcde") == 2
    end
  end

  describe "notes_count counter (pricing v2 §G)" do
    test "returns 0 for a user with no meter row" do
      user = insert(:user)
      assert UsageMeters.notes_count(user.id) == 0
    end

    test "inc_notes_count lazy-inits and accumulates across calls" do
      user = insert(:user)
      Enum.each(1..5, fn _ -> :ok = UsageMeters.inc_notes_count(user.id, 1) end)
      assert UsageMeters.notes_count(user.id) == 5
    end

    test "dec_notes_count clamps at zero (never negative)" do
      user = insert(:user)
      :ok = UsageMeters.inc_notes_count(user.id, 2)
      :ok = UsageMeters.dec_notes_count(user.id, 5)
      assert UsageMeters.notes_count(user.id) == 0
    end

    test "dec_notes_count with a zero delta is a no-op" do
      user = insert(:user)
      :ok = UsageMeters.inc_notes_count(user.id, 3)
      :ok = UsageMeters.dec_notes_count(user.id, 0)
      assert UsageMeters.notes_count(user.id) == 3
    end

    test "dec_notes_count on a missing meter row is a safe no-op" do
      user = insert(:user)
      assert UsageMeters.dec_notes_count(user.id, 1) == :ok
      assert UsageMeters.notes_count(user.id) == 0
    end

    test "recount_notes! recomputes the live count from notes (ignoring soft-deleted)" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      insert(:note, user: user, vault: vault)
      insert(:note, user: user, vault: vault)
      insert(:note, user: user, vault: vault, deleted_at: DateTime.utc_now())

      assert UsageMeters.recount_notes!(user.id) == 2
      assert UsageMeters.notes_count(user.id) == 2
    end
  end
end
