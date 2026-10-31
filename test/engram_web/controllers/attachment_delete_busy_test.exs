defmodule EngramWeb.AttachmentDeleteBusyTest do
  @moduledoc """
  The plugin's retry contract end to end: a single attachment DELETE that
  sheds on a saturated vault gate must come back through the REAL error
  renderer as 429 + `retry-after: 2`, and must not reach Sentry. The plugin
  waits `retry-after` on a 429 instead of counting it toward parking the write.
  """
  use EngramWeb.ConnCase, async: false

  alias Engram.Vaults.SeqGate

  setup %{conn: conn} do
    Sentry.Test.setup_sentry()

    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user, is_default: true)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
    lift_api_rps_cap!(user)

    prev = Application.fetch_env!(:engram, :seq_gate_wait_ms)
    Application.put_env(:engram, :seq_gate_wait_ms, 50)
    on_exit(fn -> Application.put_env(:engram, :seq_gate_wait_ms, prev) end)

    %{conn: put_req_header(conn, "authorization", "Bearer #{api_key}"), vault: vault}
  end

  test "a shed DELETE renders 429 with retry-after 2 and no Sentry event", %{
    conn: conn,
    vault: vault
  } do
    parent = self()

    holder =
      Task.async(fn ->
        SeqGate.with_vault(vault.id, fn ->
          send(parent, :held)
          receive do: (:release -> :ok)
        end)
      end)

    assert_receive :held

    {status, headers, _body} =
      assert_error_sent(429, fn -> delete(conn, "/api/attachments/photos/x.png") end)

    send(holder.pid, :release)
    Task.await(holder)

    assert status == 429
    assert {"retry-after", "2"} in headers
    assert Sentry.Test.pop_sentry_reports() == []
  end
end
