defmodule Mix.Tasks.Engram.RotateUserDekTest do
  use Engram.DataCase, async: false

  import ExUnit.CaptureIO
  import Ecto.Query, only: [from: 2]

  alias Engram.Repo

  # Stub Qdrant scroll with empty results so the rotation Qdrant sweep phase
  # passes without a real Qdrant instance. Mirrors the pattern in
  # user_dek_rotation_test.exs and rotate_user_dek_test.exs (workers).
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

  describe "run/1 — happy path" do
    test "rotates user DEK, prints rotation complete, advances dek_version", %{user: user} do
      output =
        capture_io(fn ->
          Mix.Tasks.Engram.RotateUserDek.run(["--user-id", to_string(user.id)])
        end)

      assert output =~ "rotation complete"
      assert output =~ "user_id=#{user.id}"

      reloaded =
        Repo.one!(from(u in Engram.Accounts.User, where: u.id == ^user.id),
          skip_tenant_check: true
        )

      assert reloaded.dek_version == 2
    end
  end

  describe "run/1 — missing user" do
    test "exits with {:shutdown, 3} for missing user" do
      exit_result =
        catch_exit do
          Mix.Tasks.Engram.RotateUserDek.run(["--user-id", "999999999"])
        end

      assert exit_result == {:shutdown, 3},
             "Expected {:shutdown, 3} for not_found, got #{inspect(exit_result)}"
    end

    test "prints user not found message to stderr for missing user" do
      output =
        capture_io(:stderr, fn ->
          catch_exit do
            Mix.Tasks.Engram.RotateUserDek.run(["--user-id", "999999999"])
          end
        end)

      assert output =~ "ERROR"
      assert output =~ "user not found"
    end
  end

  describe "run/1 — rotation_in_progress" do
    test "exits with shutdown 2 when lock is held", %{user: user} do
      # Hold the rotation lock so rotate_user returns :rotation_in_progress.
      Engram.Repo.update_all(
        from(u in Engram.Accounts.User, where: u.id == ^user.id),
        [set: [dek_rotation_locked_at: DateTime.utc_now()]],
        skip_tenant_check: true
      )

      exit_result =
        catch_exit do
          Mix.Tasks.Engram.RotateUserDek.run(["--user-id", to_string(user.id)])
        end

      assert exit_result == {:shutdown, 2},
             "Expected {:shutdown, 2} for rotation_in_progress, got #{inspect(exit_result)}"
    end
  end
end
