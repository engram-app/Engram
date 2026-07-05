defmodule Engram.NotesBroadcastTest do
  use Engram.DataCase, async: true

  alias Engram.Notes

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  describe "note_changed upsert broadcast (protocol rev dual-field)" do
    test "carries BOTH content and content_hash for the transition release", %{
      user: user,
      vault: vault
    } do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "a.md",
          "content" => "# A",
          "mtime" => 1.0
        })

      assert_receive %Phoenix.Socket.Broadcast{
        event: "note_changed",
        payload: payload
      }

      assert payload["event_type"] == "upsert"
      assert payload["content"] == "# A"
      assert payload["content_hash"] == note.content_hash
      assert is_binary(payload["content_hash"])
    end

    test "broadcast_from: pid excludes that subscriber", %{user: user, vault: vault} do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      {:ok, _} =
        Notes.upsert_note(
          user,
          vault,
          %{"path" => "b.md", "content" => "# B", "mtime" => 1.0},
          broadcast_from: self()
        )

      refute_receive %Phoenix.Socket.Broadcast{event: "note_changed"}, 100
    end

    test "carries a w3c traceparent when the upsert runs inside a span", %{
      user: user,
      vault: vault
    } do
      require OpenTelemetry.Tracer, as: Tracer

      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      Tracer.with_span "req" do
        {:ok, _} =
          Notes.upsert_note(user, vault, %{
            "path" => "c.md",
            "content" => "# C",
            "mtime" => 1.0
          })
      end

      assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: payload}
      assert payload.traceparent =~ ~r/\A00-[0-9a-f]{32}-[0-9a-f]{16}-0[01]\z/
    end

    test "traceparent is nil when no span is active", %{user: user, vault: vault} do
      EngramWeb.Endpoint.subscribe("sync:#{user.id}:#{vault.id}")

      {:ok, _} =
        Notes.upsert_note(user, vault, %{"path" => "d.md", "content" => "# D", "mtime" => 1.0})

      assert_receive %Phoenix.Socket.Broadcast{event: "note_changed", payload: payload}
      assert payload.traceparent == nil
    end
  end
end
