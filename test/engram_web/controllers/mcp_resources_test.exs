defmodule EngramWeb.McpResourcesTest do
  @moduledoc """
  MCP resources: notes a user attaches by hand (Claude Desktop's + menu,
  Claude Code's `@`). URIs are `engram://{vault}/{+path}`, the vault being its
  slug. Path autocomplete runs through `completion/complete`.

  Every read resolves the vault through the same credential-scoped check tool
  calls use, so these tests are mostly about what a URI must NOT reach.
  """
  use EngramWeb.ConnCase, async: true

  import Engram.Fixtures, only: [insert_note!: 3]

  setup %{conn: conn} do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    # Unlimited: some tests register a second vault.
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "Test Vault", Ecto.UUID.generate())
    {:ok, api_key, key_row} = Engram.Accounts.create_api_key(user, "test-key")
    grant_api_write!(user)

    insert_note!(user, vault, path: "Projects/Engram.md", content: "# Engram\nSECRET-A")
    insert_note!(user, vault, path: "Daily/2026-10-09.md", content: "today")
    insert_note!(user, vault, path: "Ideas/With Space.md", content: "spaced")

    %{
      conn: put_req_header(conn, "authorization", "Bearer #{api_key}"),
      user: user,
      vault: vault,
      slug: slug_of(user, vault),
      key_row: key_row
    }
  end

  defp slug_of(user, vault) do
    {:ok, v} = Engram.Vaults.get_vault(user, vault.id)
    v.slug
  end

  defp rpc(conn, method, params \\ %{}) do
    conn
    |> post("/api/mcp", %{"jsonrpc" => "2.0", "id" => 5, "method" => method, "params" => params})
    |> json_response(200)
  end

  defp page_all(conn, cursor \\ nil, acc \\ []) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}
    result = rpc(conn, "resources/list", params)["result"]
    acc = acc ++ result["resources"]

    case result["nextCursor"] do
      nil -> acc
      next -> page_all(conn, next, acc)
    end
  end

  defp read(conn, uri), do: rpc(conn, "resources/read", %{"uri" => uri})

  defp complete(conn, name, value, context \\ nil) do
    params = %{
      "ref" => %{"type" => "ref/resource", "uri" => "engram://{vault}/{+path}"},
      "argument" => %{"name" => name, "value" => value}
    }

    params = if context, do: Map.put(params, "context", %{"arguments" => context}), else: params
    rpc(conn, "completion/complete", params)["result"]["completion"]
  end

  test "initialize advertises resources and completions", %{conn: conn} do
    caps = rpc(conn, "initialize")["result"]["capabilities"]
    assert caps["resources"] == %{"listChanged" => false, "subscribe" => false}
    assert caps["completions"] == %{}
  end

  test "resources/templates/list returns the note template", %{conn: conn} do
    assert [%{"uriTemplate" => "engram://{vault}/{+path}", "mimeType" => "text/markdown"}] =
             rpc(conn, "resources/templates/list")["result"]["resourceTemplates"]
  end

  describe "resources/list" do
    test "lists recent notes with engram:// URIs", %{conn: conn, slug: slug} do
      resources = rpc(conn, "resources/list")["result"]["resources"]
      uris = Enum.map(resources, & &1["uri"])

      assert "engram://#{slug}/Projects/Engram.md" in uris
      assert "engram://#{slug}/Ideas/With%20Space.md" in uris
      assert Enum.all?(resources, &(&1["mimeType"] == "text/markdown"))
      # One vault: no vault prefix on the display name.
      assert Enum.any?(resources, &(&1["name"] == "Projects/Engram.md"))
    end

    test "prefixes names with the vault when the user has several", %{conn: conn, user: user} do
      {:ok, other, _} = Engram.Vaults.register_vault(user, "Work", Ecto.UUID.generate())
      insert_note!(user, other, path: "Plan.md", content: "plan")

      names = conn |> page_all() |> Enum.map(& &1["name"])
      assert "Work › Plan.md" in names
      assert "Test Vault › Projects/Engram.md" in names
    end

    test "pages through every note with nextCursor", %{conn: conn, user: user, vault: vault} do
      for i <- 1..60, do: insert_note!(user, vault, path: "Bulk/n#{i}.md", content: "x")

      uris = conn |> page_all() |> Enum.map(& &1["uri"])
      assert length(uris) == 63
      assert uris == Enum.uniq(uris)
    end

    test "pages into the next vault once one is exhausted", %{conn: conn, user: user} do
      {:ok, other, _} = Engram.Vaults.register_vault(user, "Work", Ecto.UUID.generate())
      insert_note!(user, other, path: "Plan.md", content: "plan")

      uris = conn |> page_all() |> Enum.map(& &1["uri"])
      assert length(uris) == 4
      assert Enum.any?(uris, &String.ends_with?(&1, "/Plan.md"))
    end

    test "a cursor offset past int8 is Invalid params, not a crash", %{conn: conn, vault: vault} do
      cursor =
        Base.url_encode64(~s({"v":"#{vault.id}","o":#{Integer.pow(10, 30)}}), padding: false)

      assert %{"error" => %{"code" => -32_602}} =
               rpc(conn, "resources/list", %{"cursor" => cursor})
    end

    test "skips empty vaults instead of returning empty pages", %{conn: conn, user: user} do
      for n <- 1..3, do: Engram.Vaults.register_vault(user, "Empty #{n}", Ecto.UUID.generate())

      result = rpc(conn, "resources/list")["result"]
      assert length(result["resources"]) == 3
      refute Map.has_key?(result, "nextCursor")
    end

    test "every listed URI resolves on read, odd characters included", %{
      conn: conn,
      user: user,
      vault: vault
    } do
      for p <- ["Odd/hash#tag.md", "Odd/q?mark.md", "Odd/100%.md", "Odd/ünïcödé.md"],
          do: insert_note!(user, vault, path: p, content: "odd")

      for %{"uri" => uri} <- page_all(conn) do
        assert %{"result" => %{"contents" => [_]}} = read(conn, uri), "unreadable: #{uri}"
      end
    end

    test "deleted notes are neither listed nor readable", %{
      conn: conn,
      user: user,
      vault: vault,
      slug: slug
    } do
      :ok = delete!(user, vault, "Daily/2026-10-09.md")

      refute conn |> page_all() |> Enum.any?(&String.contains?(&1["uri"], "Daily"))

      assert %{"error" => %{"code" => -32_002}} =
               read(conn, "engram://#{slug}/Daily/2026-10-09.md")
    end

    test "a bad cursor is Invalid params", %{conn: conn} do
      for cursor <- [
            "nope",
            Base.url_encode64("{}"),
            Base.url_encode64(~s({"v":"#{Ecto.UUID.generate()}","o":0})),
            5
          ] do
        assert %{"error" => %{"code" => -32_602}} =
                 rpc(conn, "resources/list", %{"cursor" => cursor}),
               "accepted #{inspect(cursor)}"
      end
    end

    test "omits vaults a restricted key cannot reach",
         %{conn: conn, user: user, vault: vault} = ctx do
      {:ok, other, _} = Engram.Vaults.register_vault(user, "Hidden", Ecto.UUID.generate())
      insert_note!(user, other, path: "Hidden.md", content: "x")
      restrict_key_to!(ctx.key_row, vault)

      uris = conn |> page_all() |> Enum.map(& &1["uri"])
      refute Enum.any?(uris, &String.contains?(&1, "Hidden"))
    end
  end

  describe "resources/read" do
    test "returns the note's markdown", %{conn: conn, slug: slug} do
      uri = "engram://#{slug}/Projects/Engram.md"

      assert [%{"uri" => ^uri, "mimeType" => "text/markdown", "text" => text}] =
               read(conn, uri)["result"]["contents"]

      assert text =~ "SECRET-A"
    end

    test "decodes percent-encoded paths", %{conn: conn, slug: slug} do
      assert [%{"text" => "spaced"}] =
               read(conn, "engram://#{slug}/Ideas/With%20Space.md")["result"]["contents"]
    end

    test "the URI vault is matched by slug, never by display name", %{conn: conn, user: user} do
      # "Work Notes" takes slug work-notes; a second vault NAMED "work-notes"
      # gets a suffixed slug. A by-name lookup would read the second vault.
      {:ok, a, _} = Engram.Vaults.register_vault(user, "Work Notes", Ecto.UUID.generate())
      {:ok, b, _} = Engram.Vaults.register_vault(user, "work-notes", Ecto.UUID.generate())
      insert_note!(user, a, path: "Todo.md", content: "FROM-A")
      insert_note!(user, b, path: "Todo.md", content: "FROM-B")

      assert [%{"text" => "FROM-A"}] =
               read(conn, "engram://#{slug_of(user, a)}/Todo.md")["result"]["contents"]

      assert [%{"text" => "FROM-B"}] =
               read(conn, "engram://#{slug_of(user, b)}/Todo.md")["result"]["contents"]
    end

    test "the scheme is case-insensitive", %{conn: conn, slug: slug} do
      assert %{"result" => _} = read(conn, "ENGRAM://#{slug}/Projects/Engram.md")
    end

    test "a missing note is resource-not-found", %{conn: conn, slug: slug} do
      assert %{"error" => %{"code" => -32_002}} = read(conn, "engram://#{slug}/Nope.md")
    end

    test "malformed URIs are Invalid params", %{conn: conn, slug: slug} do
      for uri <- [
            "https://#{slug}/Projects/Engram.md",
            "engram://#{slug}",
            "engram://#{slug}/",
            "nope",
            ""
          ] do
        assert %{"error" => %{"code" => -32_602}} = read(conn, uri), "accepted #{inspect(uri)}"
      end

      assert %{"error" => %{"code" => -32_602}} = rpc(conn, "resources/read", %{"uri" => 5})
      assert %{"error" => %{"code" => -32_602}} = rpc(conn, "resources/read", %{})
    end

    test "another user's note is unreachable by slug or UUID", %{conn: conn} do
      victim = insert(:user)
      {:ok, victim} = Engram.Crypto.ensure_user_dek(victim)
      # A slug the caller does NOT also own; a shared slug just resolves to
      # the caller's own vault, which proves nothing about isolation.
      {:ok, vv, _} = Engram.Vaults.register_vault(victim, "Victim Vault", Ecto.UUID.generate())
      insert_note!(victim, vv, path: "Projects/Engram.md", content: "VICTIM-SECRET")

      for ref <- [slug_of(victim, vv), vv.id] do
        body = read(conn, "engram://#{ref}/Projects/Engram.md")
        refute inspect(body) =~ "VICTIM-SECRET"
        assert %{"error" => _} = body
      end
    end

    test "out-of-scope and nonexistent vaults get the same error",
         %{conn: conn, user: user, vault: vault} = ctx do
      {:ok, other, _} = Engram.Vaults.register_vault(user, "Hidden", Ecto.UUID.generate())
      insert_note!(user, other, path: "Secret.md", content: "x")
      restrict_key_to!(ctx.key_row, vault)

      hidden = read(conn, "engram://#{slug_of(user, other)}/Secret.md")["error"]
      missing = read(conn, "engram://no-such-vault/Secret.md")["error"]
      assert hidden["code"] == missing["code"]

      assert String.replace(hidden["message"], slug_of(user, other), "X") ==
               String.replace(missing["message"], "no-such-vault", "X")
    end

    test "a restricted key cannot read a vault outside its scope",
         %{conn: conn, user: user, vault: vault} = ctx do
      {:ok, other, _} = Engram.Vaults.register_vault(user, "Hidden", Ecto.UUID.generate())
      insert_note!(user, other, path: "Secret.md", content: "OUT-OF-SCOPE")
      restrict_key_to!(ctx.key_row, vault)

      body = read(conn, "engram://#{slug_of(user, other)}/Secret.md")
      refute inspect(body) =~ "OUT-OF-SCOPE"
      assert %{"error" => _} = body
    end
  end

  describe "completion/complete" do
    test "suggests vault slugs", %{conn: conn, slug: slug} do
      assert %{"values" => [^slug]} = complete(conn, "vault", String.slice(slug, 0, 3))
    end

    test "suggests paths in the chosen vault, case-insensitively", %{conn: conn, slug: slug} do
      assert %{"values" => ["Projects/Engram.md"]} =
               complete(conn, "path", "engr", %{"vault" => slug})
    end

    test "uses the only reachable vault when none was chosen", %{conn: conn} do
      assert %{"values" => values} = complete(conn, "path", "daily")
      assert values == ["Daily/2026-10-09.md"]
    end

    test "returns nothing for another user's vault", %{conn: conn} do
      victim = insert(:user)
      {:ok, victim} = Engram.Crypto.ensure_user_dek(victim)
      {:ok, vv, _} = Engram.Vaults.register_vault(victim, "Victim", Ecto.UUID.generate())
      insert_note!(victim, vv, path: "Victim-Plan.md", content: "x")

      assert %{"values" => []} =
               complete(conn, "path", "victim", %{"vault" => slug_of(victim, vv)})
    end

    test "a restricted key gets no paths for an out-of-scope vault",
         %{conn: conn, user: user, vault: vault} = ctx do
      {:ok, other, _} = Engram.Vaults.register_vault(user, "Hidden", Ecto.UUID.generate())
      insert_note!(user, other, path: "Hidden-Plan.md", content: "x")
      restrict_key_to!(ctx.key_row, vault)

      assert %{"values" => []} =
               complete(conn, "path", "hidden", %{"vault" => slug_of(user, other)})

      assert %{"values" => []} = complete(conn, "vault", "hid")
    end

    test "prompt arguments get an empty completion, not an error", %{conn: conn} do
      result =
        rpc(conn, "completion/complete", %{
          "ref" => %{"type" => "ref/prompt", "name" => "recall"},
          "argument" => %{"name" => "topic", "value" => "x"}
        })

      assert result["result"]["completion"]["values"] == []
    end

    test "malformed params are Invalid params", %{conn: conn} do
      assert %{"error" => %{"code" => -32_602}} = rpc(conn, "completion/complete", %{"ref" => 1})
    end
  end

  defp delete!(user, vault, path) do
    case Engram.Notes.delete_note(user, vault, path) do
      :ok -> :ok
      {:ok, _} -> :ok
    end
  end

  defp restrict_key_to!(key_row, vault) do
    Engram.Repo.insert_all("api_key_vaults", [
      %{api_key_id: Ecto.UUID.dump!(key_row.id), vault_id: Ecto.UUID.dump!(vault.id)}
    ])
  end
end
