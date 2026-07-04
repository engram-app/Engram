defmodule Engram.NotesChangesPageTraceTest do
  @moduledoc """
  Catch-up-pull breadcrumb for the `/api/notes/changes` timestamp feed
  (`list_changes_page/4`).

  A reconnecting client pulls this feed to catch up on notes it missed while
  disconnected (e2e-clerk `test_23` reconnect catch-up). The failure mode is a
  note that comes back EMPTY (or missing) from the pull, so the breadcrumb logs
  what the page actually delivered — per-note `id:content_len` + count — so a CI
  flake capture can prove whether the note was returned, returned empty, or
  absent. Only NON-empty pages log (an idle poll returning nothing stays silent,
  so prod is not spammed on every poll).

  Privacy: only the note UUID + content BYTE-LENGTH are logged. Never the path
  or content.
  """
  use Engram.DataCase, async: false

  import ExUnit.CaptureLog

  alias Engram.Notes

  @epoch ~U[2020-01-01 00:00:00.000000Z]

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "Test"})
    %{user: user, vault: vault}
  end

  defp seed_notes(user, vault, n) do
    for i <- 1..n do
      {:ok, note} =
        Notes.upsert_note(user, vault, %{
          "path" => "n#{String.pad_leading(to_string(i), 3, "0")}.md",
          "content" => "note #{i}",
          "mtime" => i * 1.0
        })

      note
    end
  end

  test "a non-empty page logs a breadcrumb with count + per-note id:len", %{
    user: user,
    vault: vault
  } do
    [n1 | _] = seed_notes(user, vault, 2)

    log =
      capture_log(fn ->
        {:ok, %{changes: changes}} = Notes.list_changes_page(user, vault, @epoch, limit: 10)
        assert length(changes) == 2
      end)

    assert log =~ "changes page"
    assert log =~ "count=2"
    # per-note id:content_len — "note 1" is 6 bytes
    assert log =~ "#{n1.id}:6"
  end

  test "an empty page logs NO breadcrumb", %{user: user, vault: vault} do
    seed_notes(user, vault, 1)
    future = ~U[2999-01-01 00:00:00.000000Z]

    log =
      capture_log(fn ->
        {:ok, %{changes: []}} = Notes.list_changes_page(user, vault, future, limit: 10)
      end)

    refute log =~ "changes page"
  end
end
