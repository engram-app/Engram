# Seed script for demoing the Connections page.
#
# Run with:
#   env $(grep -v '^#' .env.demo | xargs) mix run priv/repo/seeds_connections.exs

require Logger
import Ecto.Query

alias Engram.Accounts
alias Engram.Accounts.{ApiKey, User}
alias Engram.Auth.DeviceRefreshToken
alias Engram.Billing.UserLimitOverride
alias Engram.OAuth.{Client, RefreshToken}
alias Engram.Repo
alias Engram.Vaults

ensure_user = fn email, password ->
  case Repo.one(from u in User, where: u.email == ^email) do
    nil ->
      case Accounts.create_user_with_password(email, password) do
        {:ok, user} ->
          IO.puts("  created #{email} (id=#{user.id})")
          user

        {:error, reason} ->
          raise "failed to create user #{email}: #{inspect(reason)}"
      end

    user ->
      IO.puts("  found existing #{email} (id=#{user.id})")
      user
  end
end

ensure_vault = fn user, name ->
  vault =
    case Repo.with_tenant(user.id, fn -> Vaults.list_vaults(user) end) do
      {:ok, []} ->
        {:ok, {:ok, v}} = Repo.with_tenant(user.id, fn -> Vaults.create_vault(user, %{name: name}) end)
        v

      {:ok, [v | _]} ->
        v
    end

  IO.puts("  vault id=#{vault.id} name=#{name}")
  vault
end

insert_oauth_client = fn attrs ->
  %Client{}
  |> Client.registration_changeset(attrs)
  |> Repo.insert!(skip_tenant_check: true)
end

insert_oauth_refresh_token = fn user, client, vault, opts ->
  now = DateTime.utc_now()
  raw = "engram_oauth_rt_demo_#{System.unique_integer([:positive])}"
  token_hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  rt =
    %RefreshToken{}
    |> RefreshToken.changeset(%{
      token_hash: token_hash,
      family_id: Ecto.UUID.generate(),
      client_id: client.client_id,
      user_id: user.id,
      vault_id: vault && vault.id,
      scope: "mcp",
      expires_at: DateTime.add(now, 90 * 24 * 3600, :second)
    })
    |> Repo.insert!(skip_tenant_check: true)

  Repo.update_all(
    from(t in RefreshToken, where: t.id == ^rt.id),
    set: [
      last_used_at: Keyword.get(opts, :last_used_at, DateTime.utc_now()),
      last_used_ip: Keyword.get(opts, :last_used_ip, "73.42.18.5")
    ]
  )

  rt
end

insert_device_refresh_token = fn user, vault, opts ->
  now = DateTime.utc_now() |> DateTime.truncate(:second)
  raw = "engram_device_rt_demo_#{System.unique_integer([:positive])}"
  token_hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)

  %DeviceRefreshToken{}
  |> DeviceRefreshToken.changeset(%{
    token_hash: token_hash,
    family_id: Ecto.UUID.generate(),
    user_id: user.id,
    vault_id: vault.id,
    expires_at: Keyword.get(opts, :expires_at, DateTime.add(now, 90 * 24 * 3600, :second))
  })
  |> Repo.insert!(skip_tenant_check: true)
end

insert_api_key = fn user, name ->
  {:ok, _raw, api_key} = Accounts.create_api_key(user, name)
  IO.puts("    pat #{name} id=#{api_key.id}")
  api_key
end

grant_starter_overrides = fn user ->
  # -1 means unlimited; nil in an override value falls through to plan/tier
  # defaults (see Engram.Billing.wrap_lookup/1), which would re-impose the
  # free cap on this demo user.
  overrides = [
    {"api_write_enabled", true},
    {"obsidian_connections_cap", -1},
    {"mcp_connections_cap", -1},
    {"vaults_cap", -1}
  ]

  for {key, value} <- overrides do
    %UserLimitOverride{}
    |> UserLimitOverride.changeset(%{
      user_id: user.id,
      key: key,
      value: %{"v" => value},
      reason: "demo seed: starter tier",
      set_by: "seeds_connections.exs"
    })
    |> Repo.insert!(
      on_conflict: {:replace, [:value, :reason, :set_by, :set_at]},
      conflict_target: [:user_id, :key]
    )
  end

  IO.puts("    starter overrides applied (api_write_enabled=true + unlimited caps)")
end

# ── Wipe previous demo state ───────────────────────────────────────
IO.puts("Wiping previous demo seed state...")

demo_emails = ["free@demo.local", "starter@demo.local"]

demo_user_ids =
  from(u in User, where: u.email in ^demo_emails, select: u.id)
  |> Repo.all(skip_tenant_check: true)

if demo_user_ids != [] do
  Repo.delete_all(from(t in RefreshToken, where: t.user_id in ^demo_user_ids),
    skip_tenant_check: true
  )

  Repo.delete_all(from(t in DeviceRefreshToken, where: t.user_id in ^demo_user_ids),
    skip_tenant_check: true
  )

  Repo.delete_all(from(o in UserLimitOverride, where: o.user_id in ^demo_user_ids),
    skip_tenant_check: true
  )

  for uid <- demo_user_ids do
    Repo.with_tenant(uid, fn ->
      Repo.delete_all(from(k in ApiKey, where: k.user_id == ^uid))
    end)
  end

  IO.puts("  cleared OAuth + device tokens + PATs + overrides for #{length(demo_user_ids)} demo users")
end

Repo.delete_all(
  from(c in Client, where: like(c.client_name, "Demo: %")),
  skip_tenant_check: true
)

IO.puts("  cleared demo oauth_clients (Demo: *)")

# ── FREE USER ──────────────────────────────────────────────────────
IO.puts("\n== Free user ==")
free = ensure_user.("free@demo.local", "demo1234")
free_vault = ensure_vault.(free, "Personal")

_ = insert_device_refresh_token.(free, free_vault, [])
IO.puts("  device_refresh_token (Obsidian plugin)")

claude_for_free =
  insert_oauth_client.(%{
    "client_name" => "Demo: Claude Desktop (free)",
    "software_id" => "anthropic-claude-desktop",
    "software_version" => "0.10.4",
    "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
    "scope" => "mcp",
    "kind" => "mcp",
    "first_user_agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6_1)",
    "first_ip" => "73.42.18.5"
  })

_ = insert_oauth_refresh_token.(free, claude_for_free, free_vault, last_used_ip: "73.42.18.5")
IO.puts("  oauth_refresh_token (Claude Desktop, MCP)")

# ── STARTER USER ───────────────────────────────────────────────────
IO.puts("\n== Starter user ==")
starter = ensure_user.("starter@demo.local", "demo1234")
starter_vault = ensure_vault.(starter, "Personal")
grant_starter_overrides.(starter)

_ = insert_device_refresh_token.(starter, starter_vault, [])
_ = insert_device_refresh_token.(starter, starter_vault, [])
IO.puts("  2 device_refresh_tokens (two Obsidian installs)")

claude_for_starter =
  insert_oauth_client.(%{
    "client_name" => "Demo: Claude Desktop (starter)",
    "software_id" => "anthropic-claude-desktop",
    "software_version" => "0.10.4",
    "redirect_uris" => ["https://claude.ai/api/mcp/auth_callback"],
    "scope" => "mcp",
    "kind" => "mcp",
    "first_user_agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6_1)",
    "first_ip" => "73.42.18.5"
  })

_ =
  insert_oauth_refresh_token.(starter, claude_for_starter, starter_vault,
    last_used_ip: "73.42.18.5",
    last_used_at: DateTime.add(DateTime.utc_now(), -3600, :second)
  )

cursor_for_starter =
  insert_oauth_client.(%{
    "client_name" => "Demo: Cursor",
    "software_id" => "cursor.sh",
    "software_version" => "0.42.0",
    "redirect_uris" => ["http://127.0.0.1:54321/cb"],
    "scope" => "mcp",
    "kind" => "mcp",
    "first_user_agent" => "Cursor/0.42.0",
    "first_ip" => "73.42.18.5"
  })

_ =
  insert_oauth_refresh_token.(starter, cursor_for_starter, starter_vault,
    last_used_ip: "73.42.18.5",
    last_used_at: DateTime.add(DateTime.utc_now(), -7200, :second)
  )

custom_for_starter =
  insert_oauth_client.(%{
    "client_name" => "Demo: Custom Internal Bot",
    "software_id" => "acme-internal-bot",
    "software_version" => "1.2.3",
    "redirect_uris" => ["https://internal.acme.example.com/cb"],
    "scope" => "mcp",
    "kind" => "mcp",
    "first_user_agent" => "AcmeBot/1.2.3 Python/3.11",
    "first_ip" => "104.18.5.99"
  })

_ =
  insert_oauth_refresh_token.(starter, custom_for_starter, starter_vault,
    last_used_ip: "104.18.5.99",
    last_used_at: DateTime.add(DateTime.utc_now(), -86_400, :second)
  )

IO.puts("  3 oauth_refresh_tokens (Claude Desktop verified + Cursor verified + Custom Bot unverified)")

_ = insert_api_key.(starter, "Demo: CI bot")
_ = insert_api_key.(starter, "Demo: Personal scripts")

IO.puts("\n✓ Seed complete.\n")
IO.puts("Sign in at http://localhost:5173/sign-in:")
IO.puts("  - free@demo.local / demo1234       (1 obsidian + 1 mcp, at cap)")
IO.puts("  - starter@demo.local / demo1234    (2 obsidian + 3 mcp + 2 PATs, unlimited)")
