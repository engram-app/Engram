defmodule Engram.NotesSeqFeedByteBudgetTest do
  @moduledoc """
  The seq feed pages by ROW COUNT. Nothing bounds the BYTES a page carries.

  `POST /notes` accepts a note up to 10 MB, and a catch-up page carries up to
  500 rows of full decrypted content in one WebSocket frame, so a page can try
  to build ~5 GB inside an 820 MB prod container. The frame is copied roughly
  three times on the way out (Elixir term, JSON, transport buffer), so the real
  ceiling is well under even that. A BEAM OOM kills the ECS task, which drops
  every other user on that node — one account's data shape becomes everyone's
  outage.

  The cap has to bound the DATABASE READ, not just the reply: rows are already
  loaded and decrypted before any post-hoc trim could run, and that is where
  the memory goes.

  The client tolerates short pages already: `walkOpLog` loops on `has_more` up
  to OP_LOG_MAX_PAGES (100_000), so more-but-smaller pages are free.
  """
  use Engram.DataCase, async: true
  alias Engram.{Notes, Sync, Vaults}

  setup do
    user = insert_user()
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault} = Vaults.create_vault(user, %{name: "T"})
    %{user: user, vault: vault}
  end

  defp big(kb), do: String.duplicate("x", kb * 1024)

  test "a page stops at the byte budget and reports has_more", %{user: user, vault: vault} do
    for i <- 1..5 do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "n#{i}.md", "content" => big(40)})
    end

    # Budget fits 2 notes, not 5. Row limit is deliberately generous so only the
    # byte budget can be what shortens the page.
    {:ok, %{changes: page, has_more: has_more, next: next}} =
      Notes.list_changes_by_seq(user, vault, 0, limit: 500, max_bytes: 100 * 1024)

    assert has_more, "a byte-capped page must tell the client to come back"
    assert length(page) < 5, "the budget did not shorten the page"
    assert next, "a short page must carry a cursor or the rest is unreachable"
  end

  test "resuming from the cursor returns the remainder with nothing lost", %{
    user: user,
    vault: vault
  } do
    for i <- 1..5 do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "n#{i}.md", "content" => big(40)})
    end

    # Walk the whole feed in byte-capped pages, exactly as walkOpLog does.
    paths =
      Stream.unfold({0, nil, true}, fn
        {_seq, _id, false} ->
          nil

        {seq, id, true} ->
          {:ok, %{changes: page, has_more: more, next: next}} =
            Notes.list_changes_by_seq(user, vault, seq,
              after_id: id,
              limit: 500,
              max_bytes: 100 * 1024
            )

          {next_seq, next_id} = if next, do: next, else: {seq, id}
          {Enum.map(page, & &1.path), {next_seq, next_id, more and page != []}}
      end)
      |> Enum.to_list()
      |> List.flatten()

    assert Enum.sort(paths) == Enum.sort(for i <- 1..5, do: "n#{i}.md")
  end

  test "a single note larger than the whole budget still comes back", %{
    user: user,
    vault: vault
  } do
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "huge.md", "content" => big(200)})
    {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "after.md", "content" => "small"})

    {:ok, %{changes: page}} =
      Notes.list_changes_by_seq(user, vault, 0, limit: 500, max_bytes: 10 * 1024)

    # Never zero rows: an empty page with has_more is a feed that never drains.
    # walkOpLog's stuck-cursor guard would break the loop and strand the note.
    assert [%{path: "huge.md"}] = page
  end

  test "a page under the budget is untouched", %{user: user, vault: vault} do
    for i <- 1..3 do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "n#{i}.md", "content" => "small"})
    end

    {:ok, %{changes: page, has_more: has_more}} =
      Notes.list_changes_by_seq(user, vault, 0, limit: 500, max_bytes: 4 * 1024 * 1024)

    assert length(page) == 3
    refute has_more
  end

  test "merged_changes_page applies the budget too (the channel's entry point)", %{
    user: user,
    vault: vault
  } do
    for i <- 1..5 do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "n#{i}.md", "content" => big(40)})
    end

    %{page: page, has_more: has_more} =
      Sync.merged_changes_page(user, vault, 0, nil, 500, :all, 100 * 1024)

    assert has_more
    assert length(page) < 5
  end

  test "the merged cursor never advances past a byte-truncated notes feed", %{
    user: user,
    vault: vault
  } do
    # Notes take the low seqs, attachments the high ones.
    for i <- 1..5 do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "n#{i}.md", "content" => big(40)})
    end

    for i <- 1..3 do
      {:ok, _} =
        Engram.Attachments.upsert_attachment(user, vault, %{
          "path" => "a#{i}.png",
          "content_base64" => Base.encode64("png#{i}"),
          "mime_type" => "image/png"
        })
    end

    # A budget that fits ONE note. The attachments feed is unbudgeted (metadata
    # only) and happily returns all three at seqs ABOVE every remaining note.
    %{page: page, next: next} =
      Sync.merged_changes_page(user, vault, 0, nil, 500, :all, 1024)

    {next_seq, _next_id} = next

    # Emitting an attachment here would push the shared cursor past notes 2..5,
    # which were never fetched — the client resumes after them and they are gone
    # for good. The page must stop at the last note the budget allowed.
    unfetched_note_seqs =
      Enum.filter(page, &(&1.type == :note)) |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)

    assert next_seq <= unfetched_note_seqs,
           "cursor advanced to #{next_seq}, past notes the byte budget skipped"

    refute Enum.any?(page, &(&1.type == :attachment)),
           "an attachment rode past a truncated notes feed and stranded the notes behind it"
  end

  test "the budget survives resolution inflating an empty facade (#1339 shape)", %{
    user: user,
    vault: vault
  } do
    # The pre-read probe measures the stored facade. Resolution can replace that
    # with a body rebuilt from the CRDT tail, and for a never-checkpointed note
    # the facade is "" while the whole body lives in the tail — so the probe
    # scores the page at ~0 bytes and waves through rows that inflate afterwards.
    # Whatever the facade said, the page that LEAVES must respect the budget.
    for i <- 1..5 do
      {:ok, _} = Notes.upsert_note(user, vault, %{"path" => "r#{i}.md", "content" => big(40)})
    end

    {:ok, %{changes: page, has_more: has_more, next: next}} =
      Notes.list_changes_by_seq(user, vault, 0, limit: 500, max_bytes: 100 * 1024)

    carried = page |> Enum.map(&byte_size(&1[:content] || "")) |> Enum.sum()

    assert has_more
    # One oversized note may exceed it alone; several may not.
    assert length(page) == 1 or carried <= 100 * 1024,
           "page carried #{carried} bytes over a 100 KB budget"

    # And the cursor must not point past what was actually sent.
    {next_seq, _} = next

    assert next_seq == List.last(page).seq,
           "cursor advanced past rows the trim dropped"
  end
end
