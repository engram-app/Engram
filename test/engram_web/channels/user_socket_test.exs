defmodule EngramWeb.UserSocketTest do
  # async: false. The setup mutates the global Logger level to :info; every
  # other test that does this is async: false to avoid corrupting concurrent
  # async modules (e.g. sync_channel_test) that rely on the default :warning.
  use EngramWeb.ChannelCase, async: false
  import ExUnit.CaptureLog

  alias EngramWeb.UserSocket

  require Logger

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    user = insert(:user)
    {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "socket-test")
    %{user: user, token: api_key}
  end

  test "connect stores conn_id/device_id and logs ws connect", %{token: token} do
    log =
      capture_log(fn ->
        assert {:ok, socket} =
                 connect(UserSocket, %{
                   "token" => token,
                   "conn_id" => "conn-abc",
                   "device_id" => "dev-1",
                   "vault_id" => "vault-9"
                 })

        assert socket.assigns.conn_id == "conn-abc"
        assert socket.assigns.device_id == "dev-1"
      end)

    assert log =~ "ws connect"
    assert log =~ "conn-abc"

    # Phoenix's own "CONNECTED TO ... Parameters:" line renders the connect
    # params. RedactFilter cannot help here — it scrubs metadata, never the
    # message body — so the only control is :filter_parameters. This asserts
    # the credential itself, not the presence of "[FILTERED]", because a
    # future refactor could drop the line entirely and should still pass.
    refute log =~ token
  end

  # Phoenix matches filter_parameters by SUBSTRING on the key, so the entries
  # are prefixes/fragments, not names. "token" does NOT cover device_code —
  # which redeems into both an access and a refresh token, and so is a bearer
  # credential in its own right for its 300s life.
  test "filters credential-bearing param names, not just exact matches", %{token: token} do
    log =
      capture_log(fn ->
        assert {:ok, _socket} =
                 connect(UserSocket, %{
                   "token" => token,
                   "device_code" => "dev-code-secret",
                   "code_verifier" => "pkce-secret"
                 })
      end)

    refute log =~ "dev-code-secret"
    refute log =~ "pkce-secret"
  end

  test "connect still works with no conn params (backward compatible)", %{token: token} do
    assert {:ok, socket} = connect(UserSocket, %{"token" => token})
    assert socket.assigns.conn_id == nil
  end

  # ------------------------------------------------------------------
  # plugin_version — the socket half of the compatibility floor.
  #
  # `connect/3` is the ONLY place the reported version enters the system on
  # the socket side. `ChannelGate` reads `socket.assigns[:plugin_version]`,
  # and every channel test builds its socket with `Phoenix.ChannelTest.socket/3`,
  # assigning that key by hand — so deleting the assign from `accept/5` left
  # the whole socket floor permanently fail-open with every test still green.
  # ------------------------------------------------------------------

  defp version_token(user) do
    {:ok, user} =
      user
      |> Ecto.Changeset.change(external_id: Ecto.UUID.generate())
      |> Engram.Repo.update(skip_tenant_check: true)

    {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(user.external_id, user.email)
    token
  end

  test "the plugin_version param lands in assigns", %{user: user} do
    assert {:ok, socket} =
             connect(EngramWeb.UserSocket, %{
               "token" => version_token(user),
               "plugin_version" => "1.29.0"
             })

    assert socket.assigns.plugin_version == "1.29.0"
  end

  test "a socket that sends no plugin_version assigns nil, not a crash", %{user: user} do
    assert {:ok, socket} = connect(EngramWeb.UserSocket, %{"token" => version_token(user)})

    assert socket.assigns.plugin_version == nil
  end

  # Attacker-controlled query param that lands in Logger metadata, and prod
  # serializes all metadata. Unbounded, any token holder could push ~10KB per
  # connect into a long-retention aggregator — the same failure `user_agent`
  # is truncated for in `request_logger.ex`.
  test "an over-long plugin_version is dropped before it reaches the log", %{user: user} do
    assert {:ok, socket} =
             connect(EngramWeb.UserSocket, %{
               "token" => version_token(user),
               "plugin_version" => String.duplicate("9", 10_000)
             })

    assert socket.assigns.plugin_version == nil
  end

  # NON-ASCII, deliberately. The first version of this guard used
  # `String.slice(v, 0, 32)`, which counts GRAPHEMES — and an ASCII-only test
  # cannot tell the two apart, so it passed while the bound did not exist.
  # These are the inputs that expose it.
  test "a multi-byte payload cannot smuggle bytes past the bound", %{user: user} do
    # ONE grapheme, 6001 bytes: "e" plus 3000 combining acute accents.
    combining = "e" <> String.duplicate("\u0301", 3000)
    assert String.length(combining) == 1
    assert byte_size(combining) > 32

    assert {:ok, socket} =
             connect(EngramWeb.UserSocket, %{
               "token" => version_token(user),
               "plugin_version" => combining
             })

    assert socket.assigns.plugin_version == nil

    # 32 graphemes, 128 bytes.
    assert {:ok, socket} =
             connect(EngramWeb.UserSocket, %{
               "token" => version_token(user),
               "plugin_version" => String.duplicate("😀", 32)
             })

    assert socket.assigns.plugin_version == nil
  end

  # Truncating instead of dropping would make the SOCKET stricter than HTTP for
  # the identical string: the plug feeds `supported?/1` the raw header (over 32
  # bytes -> unparsed -> allowed), so a truncated param that suddenly parses
  # below the floor would refuse sync while REST kept working.
  test "an over-long value is not truncated into a parseable one", %{user: user} do
    raw = "1.0.0-" <> String.duplicate("a", 34)
    assert byte_size(raw) > 32
    # What the HTTP plug would conclude from the same string.
    assert Engram.PluginVersion.supported?(raw)

    assert {:ok, socket} =
             connect(EngramWeb.UserSocket, %{
               "token" => version_token(user),
               "plugin_version" => raw
             })

    assert Engram.PluginVersion.supported?(socket.assigns.plugin_version)
  end

  test "a value exactly at the bound is kept", %{user: user} do
    at_bound = String.duplicate("9", 32)

    assert {:ok, socket} =
             connect(EngramWeb.UserSocket, %{
               "token" => version_token(user),
               "plugin_version" => at_bound
             })

    assert socket.assigns.plugin_version == at_bound
  end

  # `?plugin_version[]=1.0.0` decodes to a list. Dropping it keeps the assign
  # matching its `String.t() | nil` spec rather than making that a runtime lie.
  test "a non-string plugin_version becomes nil", %{user: user} do
    assert {:ok, socket} =
             connect(EngramWeb.UserSocket, %{
               "token" => version_token(user),
               "plugin_version" => ["1.0.0"]
             })

    assert socket.assigns.plugin_version == nil
  end
end
