defmodule EngramWeb.SpaRouteParityTest do
  @moduledoc """
  The Elixir half of the SPA route pin. Its twin is the
  "hard-loadable route parity with Phoenix" block in
  frontend/src/router.test.tsx; both read frontend/src/spa-routes.json.

  Why this exists: `/reset-password` had a React route and no Phoenix
  route. It resolved only because the old root `get "/:slug"` wildcard
  swallowed every unmatched single segment. Deleting that wildcard turned
  the path into a hard 404 -- breaking self-host password recovery, whose
  link is minted server-side and mailed to a locked-out user -- and the
  entire test suite stayed green, because the guard that would have caught
  it lived in TypeScript while the invariant lives in Elixir.
  """
  use ExUnit.Case, async: true

  @manifest_path Path.join([__DIR__, "..", "..", "frontend", "src", "spa-routes.json"])
  @external_resource @manifest_path

  setup_all do
    manifest = @manifest_path |> File.read!() |> Jason.decode!()
    {:ok, manifest: manifest}
  end

  describe "every hard-loadable SPA path resolves in the Phoenix router" do
    test "resolves", %{manifest: manifest} do
      unroutable =
        manifest
        |> Map.fetch!("hardLoadable")
        |> Enum.reject(fn path ->
          match?(%{}, Phoenix.Router.route_info(EngramWeb.Router, "GET", path, "app.engram.page"))
        end)

      assert unroutable == [],
             """
             These SPA paths have a React route but NO Phoenix route, so a hard
             load (typed, pasted, bookmarked, or from an email link) 404s before
             the SPA can boot:

               #{Enum.join(unroutable, "\n  ")}

             Add a `get "<path>", SpaController, :index` entry to the SPA scope in
             lib/engram_web/router.ex, or a prefix wildcard that covers it.
             """
    end

    test "each resolves to SpaController, not some other controller", %{manifest: manifest} do
      wrong =
        manifest
        |> Map.fetch!("hardLoadable")
        |> Enum.map(fn path ->
          {path, Phoenix.Router.route_info(EngramWeb.Router, "GET", path, "app.engram.page")}
        end)
        |> Enum.reject(fn {_p, info} -> match?(%{plug: EngramWeb.SpaController}, info) end)

      assert wrong == []
    end
  end

  describe "vault prefix" do
    test "the manifest's vaultPrefix is what the router actually serves", %{manifest: manifest} do
      prefix = Map.fetch!(manifest, "vaultPrefix")

      # Pins the Elixir literal to the TS `VAULT_PREFIX` (router.test.tsx
      # asserts the other direction). Renaming the prefix on one side alone
      # turns every vault hard-load into a 404; this makes that a red test.
      assert match?(
               %{plug: EngramWeb.SpaController},
               Phoenix.Router.route_info(EngramWeb.Router, "GET", prefix, "app.engram.page")
             ),
             "bare #{prefix} does not resolve"

      assert match?(
               %{plug: EngramWeb.SpaController},
               Phoenix.Router.route_info(
                 EngramWeb.Router,
                 "GET",
                 "#{prefix}/some-vault/some-id",
                 "app.engram.page"
               )
             ),
             "#{prefix}/:slug/:id does not resolve"
    end
  end

  describe "the root has no dynamic segment" do
    test "no route is a bare top-level wildcard or param" do
      # The Elixir-side twin of router.test.tsx's root-dynamic guard. A
      # dynamic segment at the root is what made every top-level path
      # ambiguous and forced the (now deleted) reserved-slug list.
      offenders =
        EngramWeb.Router.__routes__()
        |> Enum.map(& &1.path)
        |> Enum.filter(&Regex.match?(~r{\A/(:|\*)}, &1))

      assert offenders == [],
             "root-level dynamic route(s) reintroduced: #{inspect(offenders)}"
    end
  end
end
