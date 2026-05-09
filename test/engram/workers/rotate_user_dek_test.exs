defmodule Engram.Workers.RotateUserDekTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query, only: [from: 2]

  alias Engram.Repo
  alias Engram.Workers.RotateUserDek

  # Stub Qdrant scroll with empty results so the Qdrant sweep phase passes
  # without a real Qdrant instance. Mirrors the pattern in user_dek_rotation_test.exs.
  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    Bypass.stub(bypass, "POST", "/collections/engram_notes/points/scroll", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"result" => %{"points" => [], "next_page_offset" => nil}})
      )
    end)

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture(dek_version: 1)
    {:ok, bypass: bypass, user: user}
  end

  describe "perform/1" do
    test "rotates DEK and advances dek_version", %{user: user} do
      assert :ok = perform_job(RotateUserDek, %{"user_id" => user.id})

      reloaded =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id),
          skip_tenant_check: true
        )

      assert reloaded.dek_version == 2
    end

    test "discards on missing user (no retry storms)" do
      assert {:discard, :user_deleted} =
               perform_job(RotateUserDek, %{"user_id" => 999_999_999})
    end

    test "discards on malformed args" do
      assert {:discard, {:invalid_args, _}} =
               perform_job(RotateUserDek, %{"unrelated_key" => "value"})
    end

    test "snoozes with 60s and emits telemetry when rotation_in_progress", %{user: user} do
      # Hold the lock so rotate_user returns {:error, :rotation_in_progress}.
      Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

      handler_id = "snooze-telemetry-#{:erlang.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:engram, :crypto, :rotate, :dek, :snoozed],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:snooze_telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:snooze, 60} = perform_job(RotateUserDek, %{"user_id" => user.id})

      user_id = user.id
      assert_receive {:snooze_telemetry, %{count: 1, attempt: _}, %{user_id: ^user_id}}, 500
    end
  end

  describe "uniqueness" do
    test "duplicate enqueues for same user_id collapse to one job", %{user: user} do
      {:ok, job_a} = Oban.insert(RotateUserDek.new(%{"user_id" => user.id}))
      {:ok, job_b} = Oban.insert(RotateUserDek.new(%{"user_id" => user.id}))

      assert job_a.id == job_b.id
    end
  end
end
