defmodule Engram.Indexing.FreeEmbedCapTest do
  @moduledoc """
  Free embeds (dense / Voyage) at most `notes_cap` notes, oldest first. Notes
  past it stay keyword-searchable (sparse-only), with no Voyage spend.

  #2004 lowered Free `notes_cap` 10,000 -> 3,000 for NEW writes and removed
  the separate coverage cap, so a Free user already holding more than 3,000
  notes (stored under the old cap), or a downgraded paid user, got every note
  embedded. Prod did exactly that on the 0.55.0 deploy.
  """
  # async: false: flips the global :limits_enforced flag.
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  import Ecto.Query
  import Mox

  alias Engram.Billing.OverrideCache
  alias Engram.Billing.UserLimitOverride
  alias Engram.Crypto
  alias Engram.Indexing.IndexCap
  alias Engram.Notes.Chunk
  alias Engram.Notes.Note
  alias Engram.Parsers.Markdown
  alias Engram.Repo
  alias Engram.Workers.EmbedNote
  alias Engram.Workers.IndexCapMaintenance

  setup :verify_on_exit!

  setup do
    prev = Application.get_env(:engram, :limits_enforced)
    Application.put_env(:engram, :limits_enforced, true)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:engram, :limits_enforced),
        else: Application.put_env(:engram, :limits_enforced, prev)
    end)

    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)

    user = insert(:user)
    {:ok, user} = Crypto.ensure_user_dek(user)
    vault = insert(:vault, user: user)
    %{bypass: bypass, user: user, vault: vault}
  end

  defp stub_qdrant(bypass) do
    Bypass.stub(bypass, :any, :any, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)
  end

  defp expect_voyage do
    expect(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> List.duplicate(0.1, 3) end)}
    end)
  end

  defp cap!(user, n) do
    Repo.insert!(%UserLimitOverride{
      user_id: user.id,
      key: "notes_cap",
      value: %{"v" => n},
      reason: "test",
      set_by: "test"
    })

    OverrideCache.evict(user.id)
  end

  defp real_note!(user, vault, path, seconds) do
    note = Engram.Fixtures.insert_note!(user, vault, %{path: path, content: "# #{path}\n\nBody."})
    at = DateTime.add(~U[2026-01-01 00:00:00.000000Z], seconds, :second)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id), set: [created_at: at])
      end)

    Repo.get!(Note, note.id, skip_tenant_check: true)
  end

  defp reload(note), do: Repo.get!(Note, note.id, skip_tenant_check: true)

  defp chunks?(note),
    do: Repo.exists?(from(c in Chunk, where: c.note_id == ^note.id), skip_tenant_check: true)

  defp mark_dense!(note) do
    {:ok, _} =
      Repo.with_tenant(note.user_id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^note.id),
          set: [
            embed_hash: note.content_hash,
            dense_indexed_hash: note.content_hash,
            embed_model: Engram.Indexing.embed_model(),
            chunker_version: Markdown.chunker_version(),
            keyword_version: Engram.KeywordIndex.version()
          ]
        )
      end)

    Repo.insert!(
      %Chunk{
        note_id: note.id,
        user_id: note.user_id,
        vault_id: note.vault_id,
        position: 0,
        char_start: 0,
        char_end: 10,
        qdrant_point_id: Ecto.UUID.generate()
      },
      skip_tenant_check: true
    )

    reload(note)
  end

  test "Free resolves the embed cap from notes_cap (3,000)", %{user: user} do
    assert IndexCap.resolve_cap(Engram.Accounts.get_user!(user.id)) == {:cap, 3_000}
  end

  test "paid tiers and self-host are uncapped", %{user: user} do
    insert(:subscription, user: user, tier: "starter", status: "active")

    assert IndexCap.resolve_cap(Engram.Accounts.get_user_with_subscription!(user.id)) ==
             :unlimited

    Application.put_env(:engram, :limits_enforced, false)
    free = insert(:user)
    assert IndexCap.resolve_cap(Engram.Accounts.get_user!(free.id)) == :unlimited
  end

  test "with 3,001 notes the oldest 3,000 are in the cap and the newest is not",
       %{bypass: bypass, user: user, vault: vault} do
    base = ~U[2026-01-01 00:00:00.000000Z]
    now = DateTime.utc_now()
    fields = Note.__schema__(:fields)

    rows =
      for i <- 1..3_000 do
        build(:note, user: user, vault: vault, created_at: DateTime.add(base, i, :second))
        |> Map.take(fields)
        |> Map.merge(%{user_id: user.id, vault_id: vault.id, updated_at: now})
      end

    rows
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(Note, &1, skip_tenant_check: true))

    user = Engram.Accounts.get_user_with_subscription!(user.id)

    last_in_cap =
      Repo.one!(
        from(n in Note,
          where: n.user_id == ^user.id,
          order_by: [desc: n.created_at],
          limit: 1
        ),
        skip_tenant_check: true
      )

    assert IndexCap.within_cap?(last_in_cap, user)

    newest = real_note!(user, vault, "Newest.md", 10_000)
    refute IndexCap.within_cap?(newest, user)

    # No Voyage expectation: an embed call fails the test.
    stub_qdrant(bypass)
    assert :ok = perform_job(EmbedNote, %{note_id: newest.id})

    newest = reload(newest)
    assert chunks?(newest), "past the cap must stay keyword-searchable"
    assert newest.embed_hash == newest.content_hash
    assert is_nil(newest.dense_indexed_hash)
    assert DateTime.compare(newest.embed_retry_after, DateTime.utc_now()) == :gt
  end

  test "inside the cap embeds; past it is keyword-only",
       %{bypass: bypass, user: user, vault: vault} do
    cap!(user, 1)
    old = real_note!(user, vault, "Old.md", 0)
    new = real_note!(user, vault, "New.md", 10)
    stub_qdrant(bypass)

    expect_voyage()
    assert :ok = perform_job(EmbedNote, %{note_id: old.id})
    assert reload(old).dense_indexed_hash == old.content_hash

    assert :ok = perform_job(EmbedNote, %{note_id: new.id})
    new = reload(new)
    assert chunks?(new)
    assert is_nil(new.dense_indexed_hash)
  end

  test "a re-check of a keyword-indexed note past the cap parks it without rebuilding",
       %{user: user, vault: vault} do
    cap!(user, 1)
    _old = real_note!(user, vault, "Old.md", 0)
    new = real_note!(user, vault, "New.md", 10)
    new = mark_dense!(new)

    {:ok, _} =
      Repo.with_tenant(user.id, fn ->
        Repo.update_all(from(n in Note, where: n.id == ^new.id),
          set: [dense_indexed_hash: nil, embed_model: nil]
        )
      end)

    # No Voyage expectation and no Qdrant stub: any embed or index fails.
    assert :ok = perform_job(EmbedNote, %{note_id: new.id})

    parked = reload(new)
    assert parked.embed_budget_parked
    assert DateTime.compare(parked.embed_retry_after, DateTime.utc_now()) == :gt
  end

  test "deleting a note frees its slot for the next one",
       %{bypass: bypass, user: user, vault: vault} do
    cap!(user, 1)
    old = real_note!(user, vault, "Old.md", 0)
    new = real_note!(user, vault, "New.md", 10)
    stub_qdrant(bypass)

    expect_voyage()
    assert :ok = perform_job(EmbedNote, %{note_id: old.id})
    assert :ok = perform_job(EmbedNote, %{note_id: new.id})
    assert reload(new).embed_budget_parked

    :ok = Engram.Notes.delete_note(user, vault, "Old.md")
    assert :ok = IndexCap.backfill_freed_slots(user.id)

    reopened = reload(new)
    assert is_nil(reopened.embed_retry_after)

    expect_voyage()
    assert :ok = perform_job(EmbedNote, %{note_id: new.id})
    assert reload(new).dense_indexed_hash == new.content_hash
  end

  test "the delete worker enqueues the freed-slot sweep",
       %{bypass: bypass, user: user, vault: vault} do
    note = real_note!(user, vault, "Gone.md", 0)
    :ok = Engram.Notes.delete_note(user, vault, "Gone.md")
    stub_qdrant(bypass)

    assert :ok =
             perform_job(Engram.Workers.DeleteNoteIndex, %{
               note_id: note.id,
               user_id: user.id,
               vault_id: vault.id,
               path_hmac: Base.encode64(note.path_hmac)
             })

    assert_enqueued(
      worker: IndexCapMaintenance,
      args: %{"user_id" => user.id, "kind" => "backfill_slots"}
    )
  end

  test "a downgrade evicts dense vectors past the cap", %{
    bypass: bypass,
    user: user,
    vault: vault
  } do
    cap!(user, 1)
    old = mark_dense!(real_note!(user, vault, "Old.md", 0))
    new = mark_dense!(real_note!(user, vault, "New.md", 10))

    assert :ok =
             perform_job(IndexCapMaintenance, %{"user_id" => user.id, "kind" => "evict_over_cap"})

    assert reload(old).dense_indexed_hash == old.content_hash
    evicted = reload(new)
    assert is_nil(evicted.dense_indexed_hash)
    assert is_nil(evicted.embed_hash)

    # The re-index is keyword-only: no Voyage expectation.
    stub_qdrant(bypass)
    assert :ok = perform_job(EmbedNote, %{note_id: new.id})
    assert is_nil(reload(new).dense_indexed_hash)
  end
end
