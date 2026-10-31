defmodule EngramWeb.AttachmentBatchDeleteTest do
  @moduledoc """
  `POST /api/attachments/batch-delete`: the calling device's echo tag (#970)
  and the vault write gate, the same contract as the single DELETE.
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

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{api_key}")
      |> put_req_header("x-idempotency-key", Ecto.UUID.generate())

    %{conn: conn, user: user, vault: vault}
  end

  # Without the tag the plugin applied its own delete echo and trashed the
  # files it had just recreated. The `attachment_batch_delete_origin` feature
  # flag that tells the plugin it may batch ships one release LATER than this
  # stamping (a mixed-version rolling deploy must never advertise it before
  # every task stamps), so it is deliberately absent here.
  test "each delete broadcast carries the caller's X-Device-Id", ctx do
    refute Map.has_key?(EngramWeb.UserChannel.features(), :attachment_batch_delete_origin)
    %{conn: conn, user: user, vault: vault} = ctx

    {:ok, _} =
      Engram.Attachments.upsert_attachment(user, vault, %{
        "path" => "photos/a.png",
        "content_base64" => Base.encode64("a")
      })

    EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

    assert %{"deleted" => 1} =
             conn
             |> put_req_header("x-device-id", "device-a")
             |> post("/api/attachments/batch-delete", %{paths: ["photos/a.png"]})
             |> json_response(200)

    assert_receive %Phoenix.Socket.Broadcast{
      payload: %{"event_type" => "delete", "kind" => "attachment", "device_id" => "device-a"}
    }
  end

  test "a batch delete waits on a held vault gate, then sheds as 429 + retry-after 2", ctx do
    %{conn: conn, vault: vault} = ctx
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
      assert_error_sent(429, fn ->
        post(conn, "/api/attachments/batch-delete", %{paths: ["photos/x.png"]})
      end)

    send(holder.pid, :release)
    Task.await(holder)

    assert status == 429
    assert {"retry-after", "2"} in headers
    assert Sentry.Test.pop_sentry_reports() == []
  end
end
