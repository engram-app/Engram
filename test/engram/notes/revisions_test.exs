defmodule Engram.Notes.RevisionsTest do
  use Engram.DataCase, async: false

  import Ecto.Query

  alias Engram.{Crypto, Notes, Repo, Vaults}
  alias Engram.Notes.{Note, Revision, Revisions}

  setup do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Vaults.register_vault(user, "Revisions", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  defp create(user, vault, path, content) do
    {:ok, note} = Notes.upsert_note(user, vault, %{"path" => path, "content" => content})
    raw(user, note.id)
  end

  defp raw(user, id), do: tenant(user, fn -> Repo.get!(Note, id) end)

  defp record(user, existing, actor, now),
    do: tenant(user, fn -> Revisions.record_write(existing, user, actor, now) end)

  defp revisions(user, note_id),
    do: tenant(user, fn -> Repo.all(from(r in Revision, where: r.note_id == ^note_id)) end)

  defp tenant(user, fun) do
    {:ok, value} = Repo.with_tenant(user.id, fun)
    value
  end

  defp open(revs), do: Enum.find(revs, &is_nil(&1.closed_at))
  defp text_of(user, rev), do: elem(Revisions.decrypt_pending(rev, user), 1)

  test "first write: a baseline holds the old text, and a version opens", %{user: u, vault: v} do
    existing = create(u, v, "a.md", "original text")

    assert :ok = record(u, existing, "sync", DateTime.utc_now())

    revs = revisions(u, existing.id)
    baseline = Enum.find(revs, &(&1.origin == "baseline"))
    assert baseline.closed_at
    assert text_of(u, baseline) == "original text"
    assert %Revision{actor: "sync", origin: "edit"} = open(revs)
    assert length(revs) == 2
  end

  test "an empty note gets no baseline", %{user: u, vault: v} do
    existing = create(u, v, "empty.md", "")

    assert :ok = record(u, existing, "sync", DateTime.utc_now())

    assert [%Revision{closed_at: nil, actor: "sync"}] = revisions(u, existing.id)
  end

  test "same actor inside the gap changes nothing", %{user: u, vault: v} do
    existing = create(u, v, "gap.md", "one")
    t0 = existing.updated_at
    :ok = record(u, existing, "sync", t0)

    :ok = record(u, %{existing | updated_at: t0}, "sync", DateTime.add(t0, 599, :second))

    assert length(revisions(u, existing.id)) == 2
  end

  test "same actor past the gap closes the version and opens another", %{user: u, vault: v} do
    existing = create(u, v, "gap2.md", "one")
    t0 = existing.updated_at
    :ok = record(u, existing, "sync", t0)
    first_open = open(revisions(u, existing.id))

    :ok = record(u, %{existing | updated_at: t0}, "sync", DateTime.add(t0, 601, :second))

    revs = revisions(u, existing.id)
    closed = Enum.find(revs, &(&1.id == first_open.id))
    assert closed.closed_at
    assert text_of(u, closed) == "one"
    assert open(revs).id != first_open.id
  end

  test "a different actor closes your version with the exact text it replaced",
       %{user: u, vault: v} do
    existing = create(u, v, "ai.md", "draft")
    :ok = record(u, existing, "sync", DateTime.utc_now())
    yours = open(revisions(u, existing.id))

    # Setup only: change the row's text without adding a version. A "sync"
    # write inside the session gap merges into the open sync version.
    {:ok, _} =
      Notes.upsert_note(u, v, %{"path" => "ai.md", "content" => "what you typed"}, actor: "sync")

    assert length(revisions(u, existing.id)) == 2
    before_ai = raw(u, existing.id)

    :ok = record(u, before_ai, "mcp", DateTime.utc_now())

    revs = revisions(u, existing.id)
    closed = Enum.find(revs, &(&1.id == yours.id))
    assert text_of(u, closed) == "what you typed"
    assert %Revision{actor: "mcp"} = open(revs)
  end

  test "recording switched off writes nothing", %{user: u, vault: v} do
    previous = Application.get_env(:engram, :history_recording)
    Application.put_env(:engram, :history_recording, false)
    on_exit(fn -> Application.put_env(:engram, :history_recording, previous) end)

    existing = create(u, v, "off.md", "text")

    assert :skipped = record(u, existing, "sync", DateTime.utc_now())
    assert revisions(u, existing.id) == []
  end

  test "history_enabled false for the user writes nothing", %{user: u, vault: v} do
    insert(:user_limit_override, user: u, key: "history_enabled", value: %{"v" => false})
    existing = create(u, v, "denied.md", "text")

    assert :skipped = record(u, existing, "sync", DateTime.utc_now())
    assert revisions(u, existing.id) == []
  end

  test "history with no open version keeps the replaced text as an edit copy", %{
    user: u,
    vault: v
  } do
    existing = create(u, v, "orphan.md", "first")
    :ok = record(u, existing, "sync", DateTime.utc_now())

    tenant(u, fn ->
      Repo.update_all(
        from(r in Revision, where: r.note_id == ^existing.id and is_nil(r.closed_at)),
        set: [closed_at: DateTime.utc_now()]
      )
    end)

    {:ok, _} = Notes.upsert_note(u, v, %{"path" => "orphan.md", "content" => "second"})
    before_write = raw(u, existing.id)

    assert :ok = record(u, before_write, "sync", DateTime.utc_now())

    revs = revisions(u, existing.id)
    copy = Enum.find(revs, &(&1.origin == "edit" and &1.closed_at && text_of(u, &1) == "second"))
    assert copy
    assert %Revision{actor: "sync"} = open(revs)
  end

  test "decrypt_pending with no pending copy is :nothing_pending", %{user: u} do
    assert {:error, :nothing_pending} = Revisions.decrypt_pending(%Revision{}, u)
  end

  # History must never fail a save. A note id that does not exist makes the
  # baseline INSERT violate its foreign key; the savepoint absorbs it, and a
  # later statement in the SAME transaction still runs.
  test "a failure does not poison the caller's transaction", %{user: u, vault: v} do
    existing = create(u, v, "fk.md", "text")
    orphan = %{existing | id: Ecto.UUID.generate()}

    {:ok, {result, count}} =
      Repo.with_tenant(u.id, fn ->
        result = Revisions.record_write(orphan, u, "sync", DateTime.utc_now())
        {result, Repo.one(from(n in Note, select: count(n.id)))}
      end)

    assert result == :error
    assert count >= 1
  end
end
