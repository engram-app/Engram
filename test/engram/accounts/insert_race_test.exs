defmodule Engram.Accounts.InsertRaceTest do
  # async: false: CREATE TRIGGER locks the users table until the test's
  # sandbox transaction rolls back, which would stall every async test.
  use Engram.DataCase, async: false

  alias Engram.Accounts

  # The webhook's user.created and the user's first request both create the
  # same row. The loser's insert fails on whichever unique index Postgres
  # checks first, and that order is not pinned. Whatever index reports it,
  # the loser must find its own row, never answer :account_conflict (which
  # signs a brand-new user out). The trigger makes each index the reporter.
  for index <- ~w(users_clerk_id_index users_email_lower_index users_normalized_email_index) do
    test "insert lost to the same user's row (#{index} reports it) returns that row" do
      {:ok, winner} =
        Accounts.find_or_create_by_external_id("clerk_racer", %{email: "Ra.Cer@gmail.com"})

      raise_unique_on_next_insert(unquote(index))

      assert {:ok, found} = Accounts.insert_new_user("clerk_racer", "Ra.Cer@gmail.com", 1)
      assert found.id == winner.id
    end
  end

  test "insert lost to the same user's row (natural index order) returns that row" do
    {:ok, winner} =
      Accounts.find_or_create_by_external_id("clerk_racer2", %{email: "racer.two@gmail.com"})

    assert {:ok, found} = Accounts.insert_new_user("clerk_racer2", "racer.two@gmail.com", 1)
    assert found.id == winner.id
  end

  # Makes the next INSERT into users fail with a unique violation reported on
  # `index`, as if a concurrent insert had won. Rolled back with the test.
  defp raise_unique_on_next_insert(index) do
    Engram.Repo.query!("""
    CREATE FUNCTION pg_temp.raise_unique() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE unique_violation USING CONSTRAINT = '#{index}', MESSAGE = 'simulated race';
    END $$
    """)

    Engram.Repo.query!(
      "CREATE TRIGGER raise_unique BEFORE INSERT ON users FOR EACH ROW EXECUTE FUNCTION pg_temp.raise_unique()"
    )
  end
end
