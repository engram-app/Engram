defmodule Engram.MCP.HandlersUploadTargetTest do
  use Engram.DataCase, async: false

  alias Engram.MCP.Handlers
  alias Engram.MCP.Tools

  setup do
    user = insert(:user)
    vault = insert(:vault, user: user)

    prev = Application.get_env(:engram, :host_rewrite)

    # Restore by DELETING when it was unset. `HostRewrite.call/2` reads
    # `get_env(:engram, :host_rewrite, [])`, and that `[]` default only applies
    # when the key is absent — writing a literal `nil` back makes the plug's
    # `case` blow up (CaseClauseError) for every later request in the run.
    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:engram, :host_rewrite),
        else: Application.put_env(:engram, :host_rewrite, prev)
    end)

    %{user: user, vault: vault}
  end

  describe "get_attachment_upload_target" do
    # The whole point of this tool. MCP is served on mcp.engram.page, which
    # routes to the MCP endpoint and does NOT serve REST (host_rewrite.ex).
    # Deriving the upload URL from the connection would advertise
    # https://mcp.engram.page/api/attachments — a URL that cannot accept an
    # upload. It must name the configured API host instead.
    test "advertises the configured API host, not the MCP host", ctx do
      Application.put_env(:engram, :host_rewrite,
        api_host: "api.engram.page",
        mcp_host: "mcp.engram.page"
      )

      {:ok, text} = Handlers.handle("get_attachment_upload_target", ctx.user, ctx.vault, %{})

      scheme = URI.parse(EngramWeb.Endpoint.url()).scheme
      assert text =~ "#{scheme}://api.engram.page/api/attachments"
      refute text =~ "mcp.engram.page"
    end

    # Self-host runs one canonical host with no rewrite, so the endpoint URL
    # is the only correct answer there. Guards the SaaS-only-capability trap:
    # this tool must work identically on every deployment shape.
    test "falls back to the endpoint URL when no host split is configured", ctx do
      # Unset means ABSENT, which is what a self-host release actually has.
      Application.delete_env(:engram, :host_rewrite)

      {:ok, text} = Handlers.handle("get_attachment_upload_target", ctx.user, ctx.vault, %{})

      assert text =~ EngramWeb.Endpoint.url() <> "/api/attachments"
    end

    # The model needs the caller's real limits to decide whether a file can go
    # up at all, and those are per-plan. Free is text-only with a 10MB cap.
    test "reports the caller's resolved plan limits", ctx do
      {:ok, text} = Handlers.handle("get_attachment_upload_target", ctx.user, ctx.vault, %{})

      # Asserting the literal free-tier cap rather than `to_string(effective_limit(...))`:
      # that comparison is vacuous when the limit is nil (`text =~ ""` is always
      # true) and otherwise just restates the implementation back to itself.
      assert text =~ "max_bytes: 10485760"
    end

    # The vault is selected by the `x-vault-id` REQUEST HEADER (VaultPlug), not
    # by a body field. Advertising it as a body field sends the caller to the
    # user's default vault silently, which is the wrong vault whenever the
    # account has more than one.
    test "names the vault as a header, not a body field", ctx do
      {:ok, text} = Handlers.handle("get_attachment_upload_target", ctx.user, ctx.vault, %{})

      assert text =~ "x-vault-id: #{ctx.vault.id}"
      # Whitespace-insensitive: a heredoc reformat must not silently disarm this.
      refute text =~ ~r/vault_id\s+required/
    end

    # `-1` is a documented "unlimited" sentinel (billing.ex:156), and
    # `effective_limit/2` returns override values RAW — it does not normalize.
    # Rendering it literally tells the model the cap is negative, which is
    # either nonsense or reads as "uploads disabled".
    test "renders the -1 unlimited sentinel as unlimited, not a negative cap", ctx do
      insert(:user_limit_override,
        user: ctx.user,
        key: "max_file_bytes",
        value: %{"v" => -1}
      )

      Engram.Billing.OverrideCache.evict(ctx.user.id)

      {:ok, text} = Handlers.handle("get_attachment_upload_target", ctx.user, ctx.vault, %{})

      assert text =~ "max_bytes: unlimited"

      # Scoped to the limit line on purpose. A bare `refute text =~ "-1"`
      # also matches the vault UUID (e.g. 707cb1f9-1fb6-4b14-...), so it
      # passed or failed depending on which UUID the factory happened to
      # generate — green locally, red in CI, for no reason connected to
      # the behaviour under test.
      refute text =~ "max_bytes: -1"
    end
  end

  describe "tool registration" do
    test "is exposed in the MCP tool list, vault-scoped" do
      tool = Enum.find(Tools.list(), &(&1.name == "get_attachment_upload_target"))

      assert tool, "tool is not registered in Engram.MCP.Tools.list/0"
      assert is_function(tool.handler, 3)
      # `with_vault_id/1` injects this for every vault-scoped tool; without it a
      # multi-vault account cannot say which vault the upload targets.
      assert tool.inputSchema["properties"]["vault_id"]
    end
  end
end
