defmodule Engram.Notes.NoteSplitDriftFaultTest do
  @moduledoc """
  The body drift report rides on the `NoteSplit` pass that closes the
  ledger. A scan that raises (a statement timeout, a pool exit) must not
  keep the ledger open, or the Keys ids stay off on every node.
  """
  # async: false: the fault seam is global app env.
  use Engram.DataCase, async: false

  alias Engram.DataMigrations.NoteSplit
  alias Engram.Notes

  setup do
    on_exit(fn -> Application.delete_env(:engram, :note_split_drift_fault) end)

    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Fault", Ecto.UUID.generate())
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "f.md", "content" => "f"}, actor: "api")
    :ok
  end

  test "a raising drift scan is counted and the pass still closes" do
    Application.put_env(:engram, :note_split_drift_fault, fn -> raise "drift scan timed out" end)

    ref = make_ref()
    me = self()

    :telemetry.attach(
      "drifterr-#{inspect(ref)}",
      [:engram, :note_split, :body_drift_error],
      fn _, %{count: c}, _, _ -> if self() == me, do: send(me, {ref, c}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("drifterr-#{inspect(ref)}") end)

    assert :done = NoteSplit.run_pass()
    assert_received {^ref, 1}
  end
end
