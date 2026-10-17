defmodule Engram.NotesCapRaceTest do
  @moduledoc """
  notes_cap must be EXACT under concurrency (prod incident 2026-10-17: a Free
  user with a 10,000 cap ended at 10,046 notes after a bulk first sync).

  The cap used to be read in one statement and the counter bumped later in the
  insert transaction, so two creates that both read `cap - 1` both landed.

  Real connections and a park point, for the reason `CheckpointInterleave`
  documents: under the sandbox every process shares one connection in one
  never-committed transaction, so the second create would simply see the
  first one's increment and the race this pins could never happen.
  """
  use ExUnit.Case, async: false

  import Engram.Factory

  alias Engram.CheckpointInterleave
  alias Engram.Crypto
  alias Engram.Notes
  alias Engram.UsageMeters

  @point :after_notes_cap_check

  setup do
    CheckpointInterleave.checkout_real!()

    email = "cap-race-#{System.unique_integer([:positive])}-#{System.os_time()}@test.com"
    user_id = Ecto.UUID.generate()
    on_exit(fn -> CheckpointInterleave.cleanup(user_id) end)

    user = insert(:user, id: user_id, email: email)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => 2})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "CapRace", Ecto.UUID.generate())

    %{user: user, vault: vault}
  end

  defp upsert(user, vault, path) do
    Notes.upsert_note(user, vault, %{"path" => path, "content" => "# #{path}"}, actor: "api")
  end

  test "two creates that both pass the cap read at cap-1 produce exactly one note",
       %{user: user, vault: vault} do
    {:ok, _} = upsert(user, vault, "A.md")
    assert UsageMeters.notes_count(user.id) == 1

    on_exit(CheckpointInterleave.arm(@point))

    first =
      Task.async(fn ->
        CheckpointInterleave.checkout_real!()
        upsert(user, vault, "B.md")
      end)

    # The first create has read the counter (1 < 2) and holds its transaction
    # open. The second create commits on another connection in the gap.
    parked = CheckpointInterleave.await_parked(@point, first.pid)
    assert {:ok, _} = upsert(user, vault, "C.md")

    CheckpointInterleave.release(@point, parked)

    assert {:error, {:notes_cap_reached, 2, 2}} = Task.await(first, 15_000)
    assert UsageMeters.notes_count(user.id) == 2
    assert UsageMeters.recount_notes!(user.id) == 2
  end
end
