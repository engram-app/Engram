defmodule EngramWeb.Plugs.RequirePluginVersionTest do
  # async: FALSE. The wiring setup below flips `:billing_enabled` in the
  # application env, which is global — run async, it leaked into whatever
  # concurrent test happened to read it and turned six unrelated
  # MultiTenantTest cases into `onboarding_required` 403s.
  # `lifecycle_gate_channel_test.exs` is async: false for this same reason.
  use EngramWeb.ConnCase, async: false

  alias Engram.LegalFixtures
  alias Engram.Onboarding
  alias Engram.Onboarding.GateCache
  alias Engram.Vaults
  alias EngramWeb.Plugs.RequirePluginVersion

  defp with_version(conn, value),
    do: Plug.Conn.put_req_header(conn, "x-plugin-version", value)

  describe "call/2" do
    test "passes when the header is absent", %{conn: conn} do
      result = RequirePluginVersion.call(conn, [])
      refute result.halted
      assert result.assigns[:plugin_version] == nil
    end

    test "passes and records the version when at the floor", %{conn: conn} do
      result =
        conn
        |> with_version("1.28.0")
        |> RequirePluginVersion.call([])

      refute result.halted
      assert result.assigns[:plugin_version] == "1.28.0"
    end

    test "passes for an unparseable version", %{conn: conn} do
      refute conn |> with_version("nightly") |> RequirePluginVersion.call([]) |> Map.get(:halted)
    end

    test "426s below the floor with everything the client needs to recover", %{conn: conn} do
      result =
        conn
        |> with_version("1.0.0")
        |> RequirePluginVersion.call([])

      assert result.halted
      body = json_response(result, 426)
      # LITERALS, not PluginVersion.minimum()/update_url(). Asserting a value
      # against the module that produces it re-derives the answer and passes
      # even if that module is corrupted — the same trap plugin_version_test
      # opens by naming.
      assert body["error"] == "plugin_upgrade_required"
      assert body["min_version"] == "1.28.0"
      assert body["your_version"] == "1.0.0"
      assert body["update_url"] == "obsidian://show-plugin?id=engram-vault-sync"
    end

    test "records the version even on the refusal, so the block is countable", %{conn: conn} do
      result = conn |> with_version("1.0.0") |> RequirePluginVersion.call([])
      assert result.assigns[:plugin_version] == "1.0.0"
    end

    test "an over-long header is not parsed, so it never reaches the echo", %{conn: conn} do
      # The 426 body echoes `your_version`. The only thing keeping that echo
      # bounded is that `supported?/1` refuses to parse an over-long value, so
      # an over-long one can never reach the refusal branch at all. Assert the
      # absence of a response, not just `refute halted` — the old version of
      # this test claimed "nor echoed back" and checked nothing of the kind.
      result =
        conn
        |> with_version(String.duplicate("9", 5000))
        |> RequirePluginVersion.call([])

      refute result.halted
      assert result.status == nil
      assert result.resp_body == nil
    end
  end

  # Everything above calls the plug directly, which pins its BEHAVIOUR and
  # nothing about whether it runs. Deleting the `plug` line from `:authed_api`
  # left all of them green while the HTTP floor was gone entirely. This is the
  # only test that fails for that.
  describe "wiring into :authed_api" do
    setup %{conn: conn} do
      # FULLY onboarded, deliberately. The floor sits after `RequireOnboarding`
      # in the pipeline, so a half-set-up user 403s before reaching it and this
      # test would pass while proving nothing about the wiring.
      prev = Application.get_env(:engram, :billing_enabled)
      Application.put_env(:engram, :billing_enabled, true)

      LegalFixtures.insert_version(
        document: "terms_of_service",
        version: "2026-05-15",
        content_hash: "canonical",
        material: true,
        effective_date: nil
      )

      LegalFixtures.reset_version_cache()
      GateCache.evict_all()

      on_exit(fn ->
        Application.put_env(:engram, :billing_enabled, prev)
        LegalFixtures.reset_version_cache()
        GateCache.evict_all()
      end)

      user = insert_user(onboarding_profile: %{})
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
      {:ok, _vault, _} = Vaults.register_vault(user, "Floor", Ecto.UUID.generate())
      {:ok, _} = Onboarding.accept_terms(user, "2026-05-15", %{})
      {:ok, _} = Onboarding.accept_free_tier(user)
      {:ok, user} = Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})
      GateCache.evict_all()

      {:ok, conn: authenticate(conn, user), user: user}
    end

    test "a below-floor client is refused on a real vault-scoped route", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("x-plugin-version", "1.0.0")
        |> get(~p"/api/folders")

      assert json_response(conn, 426)["error"] == "plugin_upgrade_required"
    end

    # `refute conn.status == 426` would pass on a 403, a 500, or a deleted
    # plug. Assert the route actually SERVED, so this case fails if the
    # fixture stops producing a request that reaches the controller.
    test "the same route without the header is served normally", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/folders"), 200)
    end
  end
end
