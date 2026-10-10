defmodule EngramWeb.McpDekWarmupTest do
  # async: false because the test swaps the global :key_provider.
  use Engram.DataCase, async: false

  import Engram.Factory

  defmodule DownProvider do
    def name, do: :local
    def generate_dek, do: :crypto.strong_rand_bytes(32)
    def wrap_dek(_dek, _ctx), do: {:error, :kms_down}
  end

  setup do
    original = Application.get_env(:engram, :key_provider)
    Application.put_env(:engram, :key_provider, DownProvider)
    on_exit(fn -> Application.put_env(:engram, :key_provider, original) end)
    :ok
  end

  test "a failed DEK provisioning is a tool error, and the handler never runs" do
    user = insert(:user)
    vault = insert(:vault, user: user)
    parent = self()

    tool = %{
      name: "write_note",
      handler: fn _u, _v, _a ->
        send(parent, :handler_ran)
        {:ok, "ran"}
      end
    }

    {{result, status, _}, _log} =
      ExUnit.CaptureLog.with_log(fn ->
        EngramWeb.McpController.run_tool_handler(tool, user, vault, %{})
      end)

    assert status == :error
    assert {:ok, %{"isError" => true}} = result
    refute_received :handler_ran
    assert :miss = Engram.Crypto.DekCache.get(user.id)
  end
end
