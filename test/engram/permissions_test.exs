defmodule Engram.PermissionsTest do
  use Engram.DataCase, async: true

  alias Engram.Permissions

  defp conn_with(assigns), do: %Plug.Conn{assigns: assigns}

  test "no credential restrictions means every vault" do
    assert Permissions.vault_scope(conn_with(%{})) == :all
  end

  test "an OAuth grant narrows to its vault set" do
    scope = Permissions.vault_scope(conn_with(%{oauth_scope_vault_ids: ["a", "b"]}))
    assert Permissions.allows?(scope, %{id: "a"})
    refute Permissions.allows?(scope, %{id: "c"})
  end

  test "restrictions INTERSECT, never union" do
    # An API key permitted to {a, b} presenting an OAuth grant for {b, c} may
    # reach only b — the overlap. Taking either side alone would widen the
    # credential past what one of its two restrictions allows.
    #
    # Driven through `vault_scope/1`, the function production calls, rather
    # than reaching into the private intersect: the composition of the two
    # halves is the part worth pinning, and a test that skips the composition
    # would pass even if `vault_scope/1` stopped consulting one of them.
    user = insert(:user)
    a = insert(:vault, user: user)
    b = insert(:vault, user: user)
    c = insert(:vault, user: user)
    {:ok, _raw, key} = Engram.Accounts.create_api_key(user, "restricted")

    Engram.Repo.insert_all(
      "api_key_vaults",
      for v <- [a, b] do
        %{api_key_id: Ecto.UUID.dump!(key.id), vault_id: Ecto.UUID.dump!(v.id)}
      end
    )

    scope =
      Permissions.vault_scope(
        conn_with(%{
          current_api_key: key,
          oauth_scope_vault_ids: [b.id, c.id]
        })
      )

    refute Permissions.allows?(scope, a)
    assert Permissions.allows?(scope, b)
    refute Permissions.allows?(scope, c)
  end

  test "filter/2 keeps only permitted vaults, :all keeps all" do
    vaults = [%{id: "a"}, %{id: "b"}]
    assert Permissions.filter(:all, vaults) == vaults
    assert Permissions.filter(MapSet.new(["b"]), vaults) == [%{id: "b"}]
  end

  test "check/2 mirrors allows?/2" do
    assert Permissions.check(:all, %{id: "a"}) == :ok
    assert Permissions.check(MapSet.new(["b"]), %{id: "a"}) == :forbidden
  end

  test "vault_scope/1 reads a conn and a bare assigns map identically" do
    # A channel carries a Phoenix.Socket, not a conn — plugs never run for a
    # socket connect — so both shapes must resolve to the same scope.
    assigns = %{oauth_scope_vault_ids: ["a", "b"]}

    assert Permissions.vault_scope(conn_with(assigns)) == Permissions.vault_scope(assigns)
    assert Permissions.allows?(Permissions.vault_scope(assigns), %{id: "a"})
    refute Permissions.allows?(Permissions.vault_scope(assigns), %{id: "c"})
    assert Permissions.vault_scope(%{}) == :all
  end

  # Moved here when `Vaults.check_api_key_access/2` was deleted (its last caller
  # went through `Permissions` in Task 7a/7b). The behaviour it pinned — what an
  # API key's `api_key_vaults` rows mean — is now `vault_scope/1`'s API-key half,
  # and these are the only DB-backed cases in this file.
  describe "vault_scope/1 for an API key" do
    setup do
      user = insert(:user)
      %{user: user, vault: insert(:vault, user: user)}
    end

    test "no api key (JWT auth) reaches every vault" do
      assert Permissions.vault_scope(conn_with(%{current_api_key: nil})) == :all
    end

    test "an unrestricted key (no api_key_vaults rows) reaches every vault", %{user: user} do
      {:ok, _raw, key} = Engram.Accounts.create_api_key(user, "unrestricted")

      assert Permissions.vault_scope(conn_with(%{current_api_key: key})) == :all
    end

    test "a restricted key reaches its listed vault and nothing else", %{
      user: user,
      vault: vault
    } do
      other = insert(:vault, user: user)
      {:ok, _raw, key} = Engram.Accounts.create_api_key(user, "restricted")

      Engram.Repo.insert_all("api_key_vaults", [
        %{api_key_id: Ecto.UUID.dump!(key.id), vault_id: Ecto.UUID.dump!(vault.id)}
      ])

      scope = Permissions.vault_scope(conn_with(%{current_api_key: key}))

      assert Permissions.allows?(scope, vault)
      refute Permissions.allows?(scope, other)
    end
  end

  test "scope_ids_from_claims/1 covers every claim shape" do
    assert Permissions.scope_ids_from_claims(%{"vault_ids" => ["a", "b"]}) == ["a", "b"]
    # Empty list is never minted, so seeing one means a malformed token — and a
    # malformed token must DENY, not widen to all. Without the explicit clause
    # it falls through to `vault_id` and then to nil, which reads as `:all`.
    assert Permissions.scope_ids_from_claims(%{"vault_ids" => []}) == []

    # End to end: the empty claim must actually deny, not just parse to [].
    assert Permissions.vault_scope(%{oauth_scope_vault_ids: []}) != :all
    refute Permissions.allows?(Permissions.vault_scope(%{oauth_scope_vault_ids: []}), %{id: "a"})
    # Legacy scalar keeps pre-release refresh tokens bound.
    assert Permissions.scope_ids_from_claims(%{"vault_id" => "a"}) == ["a"]
    assert Permissions.scope_ids_from_claims(%{"scope" => "mcp"}) == nil
  end

  # Per-vault access levels (#174, #332). One representation for OAuth grants
  # and API keys: a level per listed vault, and a "new vaults" level for every
  # vault the credential does not list, resolved at request time.
  describe "access levels" do
    test "from_claims/1: no level claims keeps the pre-#174 meaning" do
      assert Permissions.from_claims(%{"scope" => "mcp"}) == :all
      scope = Permissions.from_claims(%{"vault_ids" => ["a"]})
      assert Permissions.level(scope, %{id: "a"}) == :write
      assert Permissions.level(scope, %{id: "new"}) == :none
    end

    test "from_claims/1: per-vault levels and the new-vaults policy" do
      scope =
        Permissions.from_claims(%{
          "vault_ids" => ["a", "b"],
          "vault_access" => %{"a" => "write", "b" => "read", "c" => "none"},
          "default_access" => "read"
        })

      assert Permissions.level(scope, %{id: "a"}) == :write
      assert Permissions.level(scope, %{id: "b"}) == :read
      assert Permissions.level(scope, %{id: "c"}) == :none
      assert Permissions.level(scope, %{id: "created-later"}) == :read
    end

    test "from_claims/1: an absent new-vaults policy means none" do
      scope = Permissions.from_claims(%{"vault_access" => %{"a" => "write"}})
      assert Permissions.level(scope, %{id: "created-later"}) == :none
    end

    test "from_claims/1: all vaults at one level" do
      assert Permissions.from_claims(%{"default_access" => "write"}) == :all
      read = Permissions.from_claims(%{"default_access" => "read"})
      assert Permissions.level(read, %{id: "any"}) == :read
    end

    test "from_claims/1: mcp:read caps every level at read" do
      scope =
        Permissions.from_claims(%{
          "scope" => "mcp:read",
          "vault_access" => %{"a" => "write"},
          "default_access" => "write"
        })

      assert Permissions.level(scope, %{id: "a"}) == :read
      assert Permissions.level(scope, %{id: "other"}) == :read

      assert Permissions.level(Permissions.from_claims(%{"scope" => "mcp:read"}), %{id: "x"}) ==
               :read
    end

    test "from_claims/1: malformed level claims deny rather than widen" do
      for claims <- [
            %{"vault_access" => "write"},
            %{"vault_access" => %{"a" => "admin"}},
            %{"default_access" => "admin"}
          ] do
        scope = Permissions.from_claims(claims)
        assert Permissions.level(scope, %{id: "a"}) == :none, inspect(claims)
      end
    end

    test "allows?/2 and allows_write?/2 follow the level" do
      scope = Permissions.from_levels(%{"a" => :write, "b" => :read}, :none)

      assert Permissions.allows?(scope, %{id: "a"}) and
               Permissions.allows_write?(scope, %{id: "a"})

      assert Permissions.allows?(scope, %{id: "b"})
      refute Permissions.allows_write?(scope, %{id: "b"})
      refute Permissions.allows?(scope, %{id: "c"})

      assert Permissions.filter(scope, [%{id: "a"}, %{id: "b"}, %{id: "c"}]) == [
               %{id: "a"},
               %{id: "b"}
             ]
    end

    test "an API key and an OAuth grant intersect to the LOWER level" do
      user = insert(:user)
      a = insert(:vault, user: user)
      b = insert(:vault, user: user)

      {:ok, _raw, key} =
        Engram.Accounts.create_api_key(user, "k", {%{to_string(a.id) => "read"}, "write"})

      oauth =
        Permissions.from_levels(%{to_string(a.id) => :write, to_string(b.id) => :read}, :write)

      scope = Permissions.vault_scope(%{oauth_access: oauth, current_api_key: key})

      assert Permissions.level(scope, a) == :read
      assert Permissions.level(scope, b) == :read
      assert Permissions.level(scope, %{id: "created-later"}) == :write
    end

    test "writable_anywhere?/2, reaches_anything?/2 and new_vault_level/1" do
      assert Permissions.writable_anywhere?(:all, [])

      assert Permissions.writable_anywhere?(Permissions.from_levels(%{"a" => :write}, :none), [
               "a"
             ])

      refute Permissions.writable_anywhere?(Permissions.from_levels(%{"a" => :read}, :read), ["a"])

      # Only LIVE listed vaults count; the new-vaults policy always does.
      refute Permissions.writable_anywhere?(Permissions.from_levels(%{"a" => :write}, :none), [
               "b"
             ])

      assert Permissions.writable_anywhere?(Permissions.from_levels(%{"a" => :none}, :write), [])
      refute Permissions.reaches_anything?(Permissions.from_levels(%{"a" => :read}, :none), ["b"])
      assert Permissions.reaches_anything?(Permissions.from_levels(%{"a" => :read}, :none), ["a"])
      assert Permissions.reaches_anything?(Permissions.from_levels(%{}, :read), [])
      assert Permissions.new_vault_level(:all) == :write
      assert Permissions.new_vault_level(Permissions.from_levels(%{}, :read)) == :read
    end

    test "parse_access_params/1" do
      assert Permissions.parse_access_params(%{}) == {:ok, nil}

      assert Permissions.parse_access_params(%{
               "vault_access" => %{"a" => "read"},
               "default_access" => "none"
             }) == {:ok, {%{"a" => "read"}, "none"}}

      # Absent policy defaults to none: picking vaults never grants future ones.
      assert Permissions.parse_access_params(%{"vault_access" => %{"a" => "write"}}) ==
               {:ok, {%{"a" => "write"}, "none"}}

      assert Permissions.parse_access_params(%{"default_access" => "read"}) ==
               {:ok, {%{}, "read"}}

      assert Permissions.parse_access_params(%{"vault_access" => %{"a" => "admin"}}) == :error
      assert Permissions.parse_access_params(%{"vault_access" => ["a"]}) == :error
      assert Permissions.parse_access_params(%{"default_access" => "admin"}) == :error
      # A grant that reaches nothing, now or later, is refused rather than minted.
      assert Permissions.parse_access_params(%{"vault_access" => %{"a" => "none"}}) == :error

      assert Permissions.parse_access_params(%{"vault_access" => %{}, "default_access" => "none"}) ==
               :error
    end
  end
end
