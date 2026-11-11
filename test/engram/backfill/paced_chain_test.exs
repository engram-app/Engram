defmodule Engram.Backfill.PacedChainTest do
  # `PacedChain.walk/5`, the hop both name backfill chains run (S1's
  # BackfillNameTerms, S2's BackfillNoteNames).
  use Engram.DataCase, async: false

  alias Engram.Backfill.PacedChain
  alias Engram.Notes.Note

  setup do
    {:ok, user} = Engram.Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    for i <- 1..3 do
      {:ok, _} =
        Engram.Notes.upsert_note(user, vault, %{"path" => "p/#{i}.md", "content" => "x"},
          actor: "api"
        )
    end

    :ok
  end

  defp counting_step(test_pid),
    do: fn ids, _ctx, n ->
      send(test_pid, {:healed, ids})
      n + length(ids)
    end

  test "continue? false before the first window: no heal, {:aborted, acc}" do
    assert {:aborted, 7} =
             PacedChain.walk(Note, nil, 7, counting_step(self()),
               stop?: fn _ -> false end,
               continue?: fn -> false end,
               batch_size: 1
             )

    refute_received {:healed, _}
  end

  test "stop? ends the hop after the window it was asked about, with that window's cursor" do
    assert {:stopped, {_user, after_id} = cursor, 1} =
             PacedChain.walk(Note, nil, 0, counting_step(self()),
               stop?: fn n -> n >= 1 end,
               batch_size: 1
             )

    assert_received {:healed, [^after_id]}
    refute_received {:healed, _}

    # The next hop resumes after that cursor and walks the rest.
    assert {:walked, 2} =
             PacedChain.walk(Note, cursor, 0, counting_step(self()),
               stop?: fn _ -> false end,
               batch_size: 1
             )
  end
end
