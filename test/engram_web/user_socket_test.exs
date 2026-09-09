defmodule EngramWeb.UserSocketTest do
  @moduledoc """
  `connect/3` is the ONLY place the reported plugin version enters the system
  on the socket side, and nothing else covered it.

  `ChannelGate` reads `socket.assigns[:plugin_version]`, and every channel test
  builds its socket with `Phoenix.ChannelTest.socket/3`, assigning that key by
  hand. So deleting the assign from `accept/5` left the whole socket floor
  permanently fail-open with every test still green — the exact silent-skip
  shape the mandatory third argument on `check/3` exists to prevent, reproduced
  one layer up.
  """
  use EngramWeb.ChannelCase, async: false

  defp token_for(user) do
    {:ok, user} =
      user
      |> Ecto.Changeset.change(external_id: Ecto.UUID.generate())
      |> Engram.Repo.update(skip_tenant_check: true)

    {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(user.external_id, user.email)
    token
  end

  setup do
    {:ok, user: insert_user(onboarding_profile: %{})}
  end

  test "the plugin_version param lands in assigns", %{user: user} do
    assert {:ok, socket} =
             connect(EngramWeb.UserSocket, %{
               "token" => token_for(user),
               "plugin_version" => "1.29.0"
             })

    assert socket.assigns.plugin_version == "1.29.0"
  end

  test "a socket that sends no plugin_version assigns nil, not a crash", %{user: user} do
    assert {:ok, socket} = connect(EngramWeb.UserSocket, %{"token" => token_for(user)})

    assert socket.assigns.plugin_version == nil
  end

  # Attacker-controlled query param that lands in Logger metadata, and prod
  # serializes all metadata. Unbounded, any token holder could push ~10KB per
  # connect into a long-retention aggregator — the same failure `user_agent`
  # is truncated for in `request_logger.ex`.
  test "an over-long plugin_version is clamped before it reaches the log", %{user: user} do
    assert {:ok, socket} =
             connect(EngramWeb.UserSocket, %{
               "token" => token_for(user),
               "plugin_version" => String.duplicate("9", 10_000)
             })

    assert byte_size(socket.assigns.plugin_version) == 32
  end

  # `?plugin_version[]=1.0.0` decodes to a list. Dropping it keeps the assign
  # matching its `String.t() | nil` spec rather than making that a runtime lie.
  test "a non-string plugin_version becomes nil", %{user: user} do
    assert {:ok, socket} =
             connect(EngramWeb.UserSocket, %{
               "token" => token_for(user),
               "plugin_version" => ["1.0.0"]
             })

    assert socket.assigns.plugin_version == nil
  end
end
