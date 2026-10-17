defmodule Engram.VaultAccessCompatTest do
  @moduledoc """
  Mixed-version safety for per-vault access levels (#174, #332).

  A release that predates levels (origin/main before this branch) reads only
  the legacy columns and claims: `vault_ids` / `vault_id` on OAuth grants
  (NULL or `[]` = every vault, write) and `api_key_vaults` rows on API keys
  (no rows = every vault, rows = write on each, `level` ignored). Every
  leveled credential must FAIL CLOSED there: an old node may grant write only
  on vaults the new grant holds at write, never read-level vaults, never
  vaults reached through the new-vaults policy, and never anything under
  `mcp:read` (an old node does not know that scope).

  The `old_*` helpers below are origin/main's code, copied verbatim in
  behaviour, applied to rows and claims the new code writes.
  """
  use Engram.DataCase, async: true

  alias Engram.{Accounts, OAuth, Permissions, Repo, Vaults}
  alias Engram.OAuth.{AuthorizationCode, RefreshToken}

  @sentinel "00000000-0000-0000-0000-000000000000"

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)

    {:ok, w, _} = Vaults.register_vault(user, "Writable", Ecto.UUID.generate())
    {:ok, r, _} = Vaults.register_vault(user, "Readable", Ecto.UUID.generate())
    {:ok, n, _} = Vaults.register_vault(user, "Hidden", Ecto.UUID.generate())

    {:ok, client} =
      OAuth.register_client(%{
        "redirect_uris" => ["https://muse.example/callback"],
        "client_name" => "Muse"
      })

    %{user: user, w: w, r: r, n: n, all: [w, r, n], client: client}
  end

  # ── origin/main, reproduced ─────────────────────────────────────────

  # origin/main `OAuth.@grant_fields`: what an old node copies from a code (or
  # a refresh token) into the refresh token it writes. No level columns.
  @old_grant_fields ~w(client_id user_id vault_id vault_ids label scope redirect_uri)a

  # origin/main `grant_vault_ids/1` + `issue_access_token/3`.
  defp old_node_claims(grant) do
    grant = Map.take(grant, @old_grant_fields)

    ids =
      case grant do
        %{vault_ids: ids} when is_list(ids) and ids != [] -> ids
        %{vault_id: id} when is_binary(id) -> [id]
        _ -> nil
      end

    %{"scope" => grant.scope}
    |> then(&if(ids, do: Map.merge(&1, %{"vault_ids" => ids, "vault_id" => hd(ids)}), else: &1))
  end

  # origin/main `Permissions.vault_scope/1` for an OAuth token: no levels, no
  # `mcp:read`. Whatever it allows, it allows to WRITE.
  defp old_reader_writes?(claims, vault) do
    case Permissions.scope_ids_from_claims(claims) do
      nil -> true
      ids -> to_string(vault.id) in ids
    end
  end

  defp old_writable(claims, vaults),
    do: for(v <- vaults, old_reader_writes?(claims, v), do: v.name)

  # ── helpers ─────────────────────────────────────────────────────────

  defp mint(ctx, scope, selection) do
    {:ok, validated} =
      OAuth.validate_authorization_request(%{
        "client_id" => ctx.client.client_id,
        "redirect_uri" => hd(ctx.client.redirect_uris),
        "response_type" => "code",
        "code_challenge" => String.duplicate("a", 43),
        "code_challenge_method" => "S256",
        "state" => "s",
        "scope" => scope
      })

    {:ok, url} = OAuth.mint_authorization_code(ctx.user, validated, selection, nil)

    {:ok, row} =
      url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("code")
      |> OAuth.get_authorization_code_by_raw()

    row
  end

  defp lv(ctx, map, default) do
    {Map.new(map, fn {k, l} -> {to_string(Map.fetch!(ctx, k).id), l} end), default}
  end

  defp new_levels(claims, vaults) do
    scope = Permissions.from_claims(claims)
    Map.new(vaults, &{&1.name, Permissions.level(scope, &1)})
  end

  # ── OAuth grants ────────────────────────────────────────────────────

  describe "an old node reading a leveled grant" do
    test "gets write only on the write-level vaults", ctx do
      row = mint(ctx, "mcp", lv(ctx, %{w: "write", r: "read", n: "none"}, "none"))

      assert row.vault_ids == [ctx.w.id]
      assert old_writable(old_node_claims(row), ctx.all) == ["Writable"]
      # ...and the new node's own token, read by an old node mid-deploy.
      assert old_writable(OAuth.access_claims(row), ctx.all) == ["Writable"]

      assert new_levels(OAuth.access_claims(row), ctx.all) ==
               %{"Writable" => :write, "Readable" => :read, "Hidden" => :none}
    end

    test "reaches nothing when write comes only from the new-vaults policy", ctx do
      row = mint(ctx, "mcp", lv(ctx, %{r: "read"}, "write"))

      assert row.vault_ids == [@sentinel]
      assert old_writable(old_node_claims(row), ctx.all) == []
      assert old_writable(OAuth.access_claims(row), ctx.all) == []

      assert new_levels(OAuth.access_claims(row), ctx.all) ==
               %{"Writable" => :write, "Readable" => :read, "Hidden" => :write}
    end

    test "reaches nothing for an all-vaults read grant", ctx do
      row = mint(ctx, "mcp", {%{}, "read"})

      assert row.vault_ids == [@sentinel]
      assert old_writable(OAuth.access_claims(row), ctx.all) == []
      assert new_levels(OAuth.access_claims(row), ctx.all)["Hidden"] == :read
    end

    test "reaches nothing for any mcp:read grant, whatever the selection", ctx do
      for selection <- [:all, [to_string(ctx.w.id)], lv(ctx, %{w: "write"}, "none")] do
        row = mint(ctx, "mcp:read", selection)

        assert row.vault_ids == [@sentinel], inspect(selection)
        assert old_writable(old_node_claims(row), ctx.all) == []
        assert old_writable(OAuth.access_claims(row), ctx.all) == []
        refute :write in Map.values(new_levels(OAuth.access_claims(row), ctx.all))
      end
    end

    test "mcp:read over every vault still reads every vault on the new node", ctx do
      row = mint(ctx, "mcp:read", :all)

      assert new_levels(OAuth.access_claims(row), ctx.all) ==
               %{"Writable" => :read, "Readable" => :read, "Hidden" => :read}
    end

    test "never stores NULL or [] for a leveled grant", ctx do
      for selection <- [
            {%{}, "read"},
            lv(ctx, %{r: "read"}, "none"),
            lv(ctx, %{r: "read"}, "write")
          ] do
        row = mint(ctx, "mcp", selection)
        assert is_list(row.vault_ids) and row.vault_ids != [], inspect(selection)
      end
    end
  end

  describe "selections an old node already understands" do
    test "every vault at write stays the legacy all-vaults grant", ctx do
      row = mint(ctx, "mcp", {%{}, "write"})

      assert {row.vault_ids, row.vault_access, row.default_access} == {nil, nil, nil}
      assert old_writable(old_node_claims(row), ctx.all) == ["Writable", "Readable", "Hidden"]
    end

    test "a legacy vault list keeps its legacy shape", ctx do
      row = mint(ctx, "mcp", [to_string(ctx.w.id)])

      assert {row.vault_ids, row.vault_access} == {[ctx.w.id], nil}
    end
  end

  describe "a new node reading what an old node wrote" do
    # An old node exchanging or refreshing a leveled grant drops the level
    # columns. The new node then reads the legacy fields alone.
    test "a refresh token written by an old node keeps write vaults, loses read ones", ctx do
      row = mint(ctx, "mcp", lv(ctx, %{w: "write", r: "read"}, "none"))
      old_row = struct(RefreshToken, Map.take(row, @old_grant_fields))

      assert new_levels(OAuth.access_claims(old_row), ctx.all) ==
               %{"Writable" => :write, "Readable" => :none, "Hidden" => :none}
    end

    test "a policy-only grant written by an old node reaches nothing", ctx do
      row = mint(ctx, "mcp", lv(ctx, %{r: "read"}, "write"))
      old_row = struct(RefreshToken, Map.take(row, @old_grant_fields))

      assert new_levels(OAuth.access_claims(old_row), ctx.all) ==
               %{"Writable" => :none, "Readable" => :none, "Hidden" => :none}
    end
  end

  describe "token size" do
    # Each listed vault costs a claim entry. Listing every vault the user
    # did NOT pick (the "none" entries) is redundant when the policy is none.
    test "stays bounded for a user with 100 vaults who picks one", ctx do
      extra =
        for i <- 1..97 do
          {:ok, v, _} = Vaults.register_vault(ctx.user, "V#{i}", Ecto.UUID.generate())
          v
        end

      access =
        Map.new([ctx.w, ctx.n | extra], &{to_string(&1.id), "none"})
        |> Map.put(to_string(ctx.r.id), "read")

      row = mint(ctx, "mcp", {access, "none"})
      claims = OAuth.access_claims(row)

      assert claims["vault_access"] == %{to_string(ctx.r.id) => "read"}
      assert claims["vault_ids"] == [@sentinel]
      assert byte_size(Accounts.generate_jwt(ctx.user, claims)) < 1_000
    end
  end

  # ── soft-deleted vaults at creation (item: "vaults you create later") ──

  describe "every vault at write while one is in the trash" do
    # A vault already in the trash at consent was never offered to the grant,
    # so restoring it later must not hand it over: it is recorded `none`, the
    # same as for an API key. That needs levels, so the pick is NOT collapsed
    # to the unrestricted NULL grant. A new SPA lists every live vault at
    # write (policy write); a stale one sends `:all`, which is normalized to
    # that same pick. Both store ONE grant: the live vaults listed at write,
    # the trashed one none, policy write.
    defp stored(row), do: Map.take(row, [:vault_id, :vault_ids, :vault_access, :default_access])

    # Everything that reads the stored grant: restore and the deleted list
    # (the LISTED level), enforcement after a session restores the trashed
    # vault, and what an old node (rollback) may write.
    defp behaviour(ctx, row) do
      scope = Permissions.from_claims(OAuth.access_claims(row))
      {:ok, _} = Vaults.restore_vault(ctx.user, ctx.n.id)
      levels = new_levels(OAuth.access_claims(row), ctx.all)
      {:ok, _} = Vaults.delete_vault(ctx.user, ctx.n.id)

      %{
        listed: Map.new(ctx.all, &{&1.name, Permissions.explicit_level(scope, &1)}),
        after_restore: levels,
        old_node: old_writable(old_node_claims(row), ctx.all),
        old_node_token: old_writable(OAuth.access_claims(row), ctx.all)
      }
    end

    test "new and stale SPAs store the same leveled grant, the trashed vault none", ctx do
      {:ok, _} = Vaults.delete_vault(ctx.user, ctx.n.id)

      new_spa = mint(ctx, "mcp", lv(ctx, %{w: "write", r: "write"}, "write"))
      stale_spa = mint(ctx, "mcp", :all)

      assert stored(stale_spa) == stored(new_spa)

      assert stored(new_spa) == %{
               vault_id: nil,
               vault_ids: Enum.sort([ctx.w.id, ctx.r.id]),
               vault_access: %{
                 to_string(ctx.w.id) => "write",
                 to_string(ctx.r.id) => "write",
                 to_string(ctx.n.id) => "none"
               },
               default_access: "write"
             }

      assert behaviour(ctx, stale_spa) == behaviour(ctx, new_spa)

      assert behaviour(ctx, new_spa) == %{
               # Restore and the deleted list need a LISTED write: either grant
               # can restore a live vault it later deletes, never the trashed one.
               listed: %{"Writable" => :write, "Readable" => :write, "Hidden" => :none},
               after_restore: %{"Writable" => :write, "Readable" => :write, "Hidden" => :none},
               # Rollback: an old node writes the vaults that were live at
               # consent and never the restored one (narrowed, never widened).
               old_node: ["Writable", "Readable"],
               old_node_token: ["Writable", "Readable"]
             }
    end

    test "with nothing in the trash it stays the unrestricted NULL grant", ctx do
      new_spa = mint(ctx, "mcp", lv(ctx, %{w: "write", r: "write", n: "write"}, "write"))
      stale_spa = mint(ctx, "mcp", :all)

      for row <- [new_spa, stale_spa] do
        assert {row.vault_ids, row.vault_access, row.default_access} == {nil, nil, nil}
      end
    end
  end

  describe "a vault soft-deleted when the credential is created" do
    # Under ANY non-none policy, read as much as write: a read policy would
    # otherwise hand the restored vault over at read.
    for policy <- ["write", "read"] do
      test "is recorded as none on a grant with a #{policy} policy", ctx do
        {:ok, _} = Vaults.delete_vault(ctx.user, ctx.n.id)
        row = mint(ctx, "mcp", lv(ctx, %{w: "write"}, unquote(policy)))

        assert row.vault_access[to_string(ctx.n.id)] == "none"
        {:ok, _} = Vaults.restore_vault(ctx.user, ctx.n.id)
        assert new_levels(OAuth.access_claims(row), [ctx.n]) == %{"Hidden" => :none}
      end

      test "is recorded as none on a key with a #{policy} policy", ctx do
        {:ok, _} = Vaults.delete_vault(ctx.user, ctx.n.id)
        {:ok, raw, _} = Accounts.create_api_key(ctx.user, "k", {%{}, unquote(policy)})
        {:ok, _} = Vaults.restore_vault(ctx.user, ctx.n.id)

        {:ok, _user, key} = Accounts.validate_api_key(raw)
        scope = Vaults.accessible_vault_ids(key)
        assert Permissions.level(scope, ctx.n) == :none
        assert Permissions.level(scope, ctx.w) == String.to_existing_atom(unquote(policy))
      end
    end
  end

  # ── API keys ────────────────────────────────────────────────────────

  describe "API keys on an old node" do
    # origin/main `Accounts.lookup_key/1`: `key_hash == sha256_hex(raw)`, and
    # zero `api_key_vaults` rows read as every vault, write.
    defp old_lookup(raw) do
      hash = Engram.Crypto.sha256_hex(raw)

      Repo.one(from(k in Engram.Accounts.ApiKey, where: k.key_hash == ^hash),
        skip_tenant_check: true
      )
    end

    test "a leveled key is not found at all (401), whatever its levels", ctx do
      for access <- [{%{}, "read"}, lv(ctx, %{w: "write", r: "read"}, "none"), {%{}, "write"}] do
        {:ok, raw, _} = Accounts.create_api_key(ctx.user, "k", access)

        assert old_lookup(raw) == nil, inspect(access)
        assert {:ok, _, _} = Accounts.validate_api_key(raw)
      end
    end

    test "a pre-levels key is found exactly as before", ctx do
      {:ok, raw, key} = Accounts.create_api_key(ctx.user, "k")

      assert old_lookup(raw).id == key.id
    end

    test "a leveled key's raw form cannot collide with a pre-levels key", ctx do
      # A pre-levels key whose random part happens to start with the leveled
      # prefix keeps hashing the old way: the leveled form is longer.
      raw = "engram_lk_" <> String.duplicate("A", 40)
      {:ok, key} = insert_legacy_key(ctx.user, raw)

      assert {:ok, _, found} = Accounts.validate_api_key(raw)
      assert found.id == key.id
    end
  end

  # A key that predates levels (created before the levels migration ran,
  # `Accounts.pre_levels_key?/1`) restored and listed every deleted vault it
  # reaches, whenever the vault was deleted. Levels must not change that: the
  # created-at bound is for every key created since, and OAuth grants.
  describe "a pre-levels key and the trash" do
    import Phoenix.ConnTest
    import Plug.Conn, only: [put_req_header: 3]
    @endpoint EngramWeb.Endpoint

    setup ctx do
      insert(:user_limit_override, user: ctx.user, key: "api_rps_cap", value: %{"v" => 100})
      :ok
    end

    defp backdate_deletion(user, vault) do
      {:ok, _} = Vaults.delete_vault(user, vault.id)
      id = vault.id

      Repo.update_all(
        from(v in Engram.Vaults.Vault, where: v.id == ^id),
        [set: [deleted_at: DateTime.add(DateTime.utc_now(:second), -3600, :second)]],
        skip_tenant_check: true
      )
    end

    defp key_conn(raw), do: put_req_header(build_conn(), "authorization", "Bearer #{raw}")

    test "an all-vaults key lists and restores a vault deleted before it", ctx do
      backdate_deletion(ctx.user, ctx.n)
      {:ok, raw, key} = Accounts.create_api_key(ctx.user, "legacy")
      assert key.default_access == nil
      key_id = key.id

      # Created before the levels migration ran on this database.
      Repo.update_all(
        from(k in Engram.Accounts.ApiKey, where: k.id == ^key_id),
        [set: [created_at: ~U[2026-01-01 00:00:00Z]]],
        skip_tenant_check: true
      )

      Engram.Cache.evict(:api_key, key.key_hash)

      ids =
        raw
        |> key_conn()
        |> get("/api/vaults?deleted=true")
        |> json_response(200)
        |> Map.fetch!("vaults")
        |> Enum.map(& &1["id"])

      assert to_string(ctx.n.id) in ids
      assert (raw |> key_conn() |> post("/api/vaults/#{ctx.n.id}/restore")).status == 200
    end

    test "a leveled all-write key still cannot restore one deleted before it", ctx do
      backdate_deletion(ctx.user, ctx.n)
      {:ok, raw, _} = Accounts.create_api_key(ctx.user, "leveled", {%{}, "write"})

      refute (raw |> key_conn() |> post("/api/vaults/#{ctx.n.id}/restore")).status == 200
    end
  end

  defp insert_legacy_key(user, raw) do
    {:ok, key} =
      Repo.with_tenant(user.id, fn ->
        %Engram.Accounts.ApiKey{}
        |> Engram.Accounts.ApiKey.changeset(%{
          key_hash: Engram.Crypto.sha256_hex(raw),
          name: "legacy",
          user_id: user.id
        })
        |> Repo.insert!()
      end)

    {:ok, key}
  end

  # Keeps the aliases honest: both are the schemas the old reader reads.
  test "the copied old grant fields exist on both grant schemas" do
    for schema <- [AuthorizationCode, RefreshToken], f <- @old_grant_fields do
      assert f in schema.__schema__(:fields), "#{inspect(schema)} lacks #{f}"
    end
  end
end
