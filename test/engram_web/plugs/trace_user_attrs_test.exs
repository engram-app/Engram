defmodule EngramWeb.Plugs.TraceUserAttrsTest do
  use EngramWeb.ConnCase, async: true
  alias EngramWeb.Plugs.TraceUserAttrs

  test "builds hashed user_id + vault_id attrs from assigns" do
    conn =
      build_conn()
      |> Plug.Conn.assign(:current_user, %{id: "user_123"})
      |> Plug.Conn.assign(:current_vault, %{id: "vault_abc"})

    attrs = TraceUserAttrs.attrs_for(conn)
    # user_id MUST use the SAME keyed HMAC as log metadata (Engram.Crypto.HMAC.hash_user_id/1)
    # so traces filter/correlate against the same user_id value that appears in Loki logs.
    assert {"app.user_id", Engram.Crypto.HMAC.hash_user_id("user_123")} in attrs
    assert {"app.vault_id", "vault_abc"} in attrs
  end

  test "omits pairs when assigns are absent" do
    assert TraceUserAttrs.attrs_for(build_conn()) == []
  end

  test "stamps plugin.version and app.device_id so a flood names its client" do
    conn =
      build_conn()
      |> Plug.Conn.assign(:plugin_version, "1.39.3")
      |> Plug.Conn.put_req_header("x-device-id", "dev-abc")

    attrs = TraceUserAttrs.attrs_for(conn)
    assert {"plugin.version", "1.39.3"} in attrs
    assert {"app.device_id", "dev-abc"} in attrs
  end

  test "drops an over-long or non-version plugin.version instead of truncating it" do
    for bad <- [String.duplicate("9", 500), "1.0 /home/u/vault"] do
      conn = build_conn() |> Plug.Conn.assign(:plugin_version, bad)
      refute List.keyfind(TraceUserAttrs.attrs_for(conn), "plugin.version", 0)
    end
  end

  test "drops a non-ASCII value instead of letting one grapheme carry many bytes" do
    combining = "a" <> String.duplicate("\u0301", 2_000)
    conn = build_conn() |> Plug.Conn.assign(:plugin_version, combining)

    refute List.keyfind(TraceUserAttrs.attrs_for(conn), "plugin.version", 0)
  end
end
