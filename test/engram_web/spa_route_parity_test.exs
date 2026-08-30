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

  # No @external_resource: it only triggers recompilation for .ex files, and
  # this is a .exs test that ExUnit reads fresh on every run anyway.
  @manifest_path Path.join([__DIR__, "..", "..", "frontend", "src", "spa-routes.json"])

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

  describe "retired and over-deep paths must NOT resolve" do
    test "each mustNotResolve sample has no route", %{manifest: manifest} do
      # The manifest's other direction. A list of routes that EXIST is
      # structurally unable to catch a wildcard that grew too greedy: a
      # `get "/v/*path"` made `/v/work/n-1/extra` a 200 SPA shell rendering an
      # in-app 404, which reports healthy to an uptime monitor and gets
      # indexed as a soft-404 -- the exact class the deleted deny-list existed
      # to prevent, reintroduced one level down.
      resolving =
        manifest
        |> Map.fetch!("mustNotResolve")
        |> Enum.filter(fn path ->
          match?(%{}, Phoenix.Router.route_info(EngramWeb.Router, "GET", path, "app.engram.page"))
        end)

      assert resolving == [],
             """
             These paths resolve but must not -- either a retired URL shape came
             back, or a wildcard is greedier than the React routes it mirrors:

               #{Enum.join(resolving, "\n  ")}
             """
    end
  end

  describe "every SPA route in Phoenix has a React counterpart" do
    test "no SpaController route is missing from the manifest", %{manifest: manifest} do
      # The reverse direction, which the first version of this test lacked.
      # `get "/search"` and `get "/billing"` were Phoenix SPA routes with no
      # React route -- dead for months, every test green, found by hand. A
      # manifest sample must exercise each one.
      samples = Map.fetch!(manifest, "hardLoadable")

      spa_routes =
        EngramWeb.Router.__routes__()
        |> Enum.filter(&(&1.plug == EngramWeb.SpaController and &1.verb == :get))
        |> Enum.map(& &1.path)
        |> Enum.uniq()

      unexercised =
        Enum.reject(spa_routes, fn route ->
          Enum.any?(samples, fn sample ->
            case Phoenix.Router.route_info(EngramWeb.Router, "GET", sample, "app.engram.page") do
              %{route: ^route} -> true
              _ -> false
            end
          end)
        end)

      assert unexercised == [],
             """
             These Phoenix SPA routes are not exercised by any manifest sample,
             so nothing proves the React router serves them:

               #{Enum.join(unexercised, "\n  ")}

             Either add a sample to frontend/src/spa-routes.json, or delete the
             route if (like /search and /billing) it has no React counterpart.
             """
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
