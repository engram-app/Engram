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
end
