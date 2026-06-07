defmodule Engram.NotesCapTest do
  @moduledoc """
  Pins the maintained `usage_meters.notes_count` counter that replaced the
  per-insert `COUNT(*)` for notes_cap enforcement. Every path that changes a
  user's live-note count must keep the counter consistent.
  """
  use Engram.DataCase, async: true

  alias Engram.Notes
  alias Engram.UsageMeters

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  defp upsert(user, vault, path, content \\ "# Note\nbody") do
    Notes.upsert_note(user, vault, %{"path" => path, "content" => content, "mtime" => 1_000.0})
  end

  test "starts at zero for a fresh user", %{user: user} do
    assert UsageMeters.notes_count(user.id) == 0
  end

  test "increments on create, decrements on soft-delete", %{user: user, vault: vault} do
    {:ok, _} = upsert(user, vault, "A.md")
    {:ok, _} = upsert(user, vault, "B.md")
    assert UsageMeters.notes_count(user.id) == 2

    :ok = Notes.delete_note(user, vault, "A.md")
    assert UsageMeters.notes_count(user.id) == 1
  end

  test "updating an existing note does not change the counter", %{user: user, vault: vault} do
    {:ok, _} = upsert(user, vault, "A.md", "v1")
    assert UsageMeters.notes_count(user.id) == 1

    {:ok, _} = upsert(user, vault, "A.md", "v2 updated body")
    assert UsageMeters.notes_count(user.id) == 1
  end

  test "soft-delete is idempotent for the counter", %{user: user, vault: vault} do
    {:ok, _} = upsert(user, vault, "A.md")
    :ok = Notes.delete_note(user, vault, "A.md")
    :ok = Notes.delete_note(user, vault, "A.md")
    assert UsageMeters.notes_count(user.id) == 0
  end

  test "never drops below zero", %{user: user, vault: vault} do
    :ok = Notes.delete_note(user, vault, "does-not-exist.md")
    assert UsageMeters.notes_count(user.id) == 0
  end

  test "enforces notes_cap from the maintained counter", %{user: user, vault: vault} do
    insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => 2})

    {:ok, _} = upsert(user, vault, "A.md")
    {:ok, _} = upsert(user, vault, "B.md")
    assert {:error, {:notes_cap_reached, 2, 2}} = upsert(user, vault, "C.md")

    # The rejected insert must not have bumped the counter.
    assert UsageMeters.notes_count(user.id) == 2
  end

  test "deleting under the cap frees a slot", %{user: user, vault: vault} do
    insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => 2})

    {:ok, _} = upsert(user, vault, "A.md")
    {:ok, _} = upsert(user, vault, "B.md")
    assert {:error, {:notes_cap_reached, 2, 2}} = upsert(user, vault, "C.md")

    :ok = Notes.delete_note(user, vault, "A.md")
    assert {:ok, _} = upsert(user, vault, "C.md")
    assert UsageMeters.notes_count(user.id) == 2
  end

  test "folder markers do not count toward the note quota",
       %{user: user, vault: vault} do
    insert(:user_limit_override, user: user, key: "notes_cap", value: %{"v" => 1})

    # One real note hits the cap.
    {:ok, _} = upsert(user, vault, "A.md")
    assert UsageMeters.notes_count(user.id) == 1

    # A marker must not push the counter — and must not be rejected by the cap.
    assert {:ok, _} = Notes.create_folder_marker(user, vault, "Free")
    assert UsageMeters.notes_count(user.id) == 1

    # A second real note must still be rejected because the cap is still full.
    assert {:error, {:notes_cap_reached, 1, 1}} = upsert(user, vault, "B.md")
  end

  test "recount_notes! ignores folder markers", %{user: user, vault: vault} do
    {:ok, _} = upsert(user, vault, "A.md")
    {:ok, _} = Notes.create_folder_marker(user, vault, "Free")

    # Drift the counter so we can prove recount picks the kind='note' floor.
    :ok = UsageMeters.inc_notes_count(user.id, 50)
    assert UsageMeters.notes_count(user.id) == 51

    assert UsageMeters.recount_notes!(user.id) == 1
    assert UsageMeters.notes_count(user.id) == 1
  end
end
