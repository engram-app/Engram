defmodule Engram.FreeStampBlock do
  @moduledoc """
  Makes `Engram.Onboarding.stamp_free_tier/1` fail for real: a BEFORE UPDATE
  trigger skips the row whenever the Free stamp would change, so the
  conditional update matches zero rows and the stamp reports `:not_found`.

  Created inside the test's sandbox transaction, so it rolls back with it.
  DDL locks `users` until then, so only use it from an `async: false` module.
  """

  @doc "Install the trigger."
  def block! do
    Engram.Repo.query!("""
    CREATE FUNCTION test_block_free_stamp() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.free_tier_accepted_at IS DISTINCT FROM OLD.free_tier_accepted_at THEN
        RETURN NULL;
      END IF;
      RETURN NEW;
    END $$
    """)

    Engram.Repo.query!("""
    CREATE TRIGGER test_block_free_stamp BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION test_block_free_stamp()
    """)

    :ok
  end

  @doc "Drop the trigger again."
  def unblock! do
    Engram.Repo.query!("DROP TRIGGER test_block_free_stamp ON users")
    :ok
  end
end
