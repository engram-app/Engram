defmodule Engram.Notes.CrdtCleanFlagTest do
  @moduledoc """
  A room bound clean skips its exit checkpoint (`CrdtPersistence.unbind/3`).
  Any update after bind must end that, even one whose tail append raises
  before it is counted as a failure: the room then crashes into unbind with
  no tail id and no failure recorded, and only the flag says the doc moved.
  """
  # async: false: the append fault seam is global app env.
  use Engram.DataCase, async: false

  alias Engram.Notes.CrdtPersistence

  setup do
    prev = Application.get_env(:engram, :crdt_tail_append_fault)
    on_exit(fn -> Application.put_env(:engram, :crdt_tail_append_fault, prev) end)
    :ok
  end

  test "an update whose append raises still clears the clean flag" do
    user = insert(:user)
    Application.put_env(:engram, :crdt_tail_append_fault, fn -> raise "append failed" end)
    Process.put(:crdt_clean, true)

    state = %{
      user_id: user.id,
      vault_id: Ecto.UUID.generate(),
      note_id: Ecto.UUID.generate(),
      user: user
    }

    assert_raise RuntimeError, "append failed", fn ->
      CrdtPersistence.update_v1(state, <<0>>, "doc", nil)
    end

    refute Process.get(:crdt_clean)
  end
end
