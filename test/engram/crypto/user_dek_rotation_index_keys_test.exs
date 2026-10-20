defmodule Engram.Crypto.UserDekRotationIndexKeysTest do
  @moduledoc """
  Every key the index matches on derives from the DEK: the Qdrant filter
  HMACs (`Crypto.dek_filter_key/1`) and the chunk-reuse fingerprints
  (`Crypto.dek_content_hash_key/1`). A rotation that rewraps only the point
  text leaves type/tag/folder/path filters matching nothing, and makes the
  next index of every note re-embed every chunk.

  Qdrant is a small in-memory fake behind Bypass: it keeps each point's
  payload and applies `set_payload`, so a search's filter can be evaluated
  against what a point actually holds.
  """
  use Engram.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Mox

  alias Engram.Crypto
  alias Engram.Crypto.UserDekRotation
  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.Chunk
  alias Engram.Search

  setup :verify_on_exit!

  @content """
  ---
  type: Playbook
  tags: [ops, oncall]
  ---
  # Pager Runbook

  Intro paragraph about the pager.

  ## Escalation

  Page the secondary after fifteen minutes.

  ## Handoff

  Write the handoff note before signing off.
  """

  setup do
    {:ok, store} = Agent.start_link(fn -> %{points: %{}, queries: [], upserts: 0} end)
    bypass = Bypass.open()
    Engram.ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")
    Bypass.stub(bypass, :any, :any, &fake_qdrant(&1, store))

    {:ok, user} = Engram.Fixtures.user_with_dek_fixture(dek_version: 1)
    vault = Engram.Fixtures.insert_vault!(user, "KeysVault")

    {:ok, note} =
      Notes.upsert_note(user, vault, %{"path" => "Ops/Pager.md", "content" => @content},
        actor: "api"
      )

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      send(self(), {:embedded, texts})
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    stub(Engram.MockEmbedder, :embed_texts, fn texts, _opts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    assert {:ok, chunks} = Indexing.index_note(fresh(note, user), vault)
    assert chunks > 2, "the fixture must produce several chunks"
    assert drain_embedded() != [], "the first index embeds"

    %{user: user, vault: vault, note: note, store: store}
  end

  test "the filter HMACs on every point equal what a search sends after the rotation", ctx do
    assert :ok = UserDekRotation.rotate_user(ctx.user.id)
    user = reload_user(ctx.user)

    for {opts, key} <- [
          {[type: "Playbook"], "type_hmac"},
          {[tags: ["ops"]], "tags_hmac"},
          {[folder: "Ops"], "folder_hmac"}
        ] do
      assert {:ok, _} = Search.search(user, ctx.vault, "pager", [mode: :vector] ++ opts)
      filter = last_query_filter(ctx.store)
      assert Enum.any?(filter, &(&1["key"] == key)), "the search must filter on #{key}"

      ids = point_ids(ctx.note)
      matched = for id <- ids, matches?(point(ctx.store, id), filter), do: id

      assert Enum.sort(matched) == Enum.sort(ids),
             "#{key}: a #{inspect(opts)} search must still find every chunk of the note"
    end

    raw = Repo.one!(from(n in Notes.Note, where: n.id == ^ctx.note.id), skip_tenant_check: true)

    for id <- point_ids(ctx.note),
        do: assert(point(ctx.store, id)["path_hmac"] == Base.encode64(raw.path_hmac))
  end

  test "re-indexing the unchanged note after the rotation embeds nothing", ctx do
    assert :ok = UserDekRotation.rotate_user(ctx.user.id)
    user = reload_user(ctx.user)
    before = point_ids(ctx.note)
    upserts = Agent.get(ctx.store, & &1.upserts)

    assert {:ok, _} = Indexing.index_note(fresh(ctx.note, user), ctx.vault)

    assert drain_embedded() == [], "a rotation must cost nothing in Voyage"
    assert Agent.get(ctx.store, & &1.upserts) == upserts, "no point is rewritten"
    assert Enum.sort(point_ids(ctx.note)) == Enum.sort(before), "every point is reused"
  end

  test "the note's content hashes move to the new key, so EmbedNote still skips it", ctx do
    assert :ok = UserDekRotation.rotate_user(ctx.user.id)
    {:ok, new_key} = Crypto.dek_content_hash_key(reload_user(ctx.user))

    raw = Repo.one!(from(n in Notes.Note, where: n.id == ^ctx.note.id), skip_tenant_check: true)
    assert raw.content_hash == Crypto.hmac_content_hash(new_key, @content)
    assert raw.embed_hash == raw.content_hash
  end

  # ---------------------------------------------------------------------------

  defp reload_user(user), do: Repo.reload!(user, skip_tenant_check: true)

  defp fresh(note, user) do
    {:ok, note} =
      note
      |> Repo.reload!(skip_tenant_check: true)
      |> Crypto.maybe_decrypt_note_fields(reload_user(user))

    note
  end

  defp drain_embedded do
    receive do
      {:embedded, texts} -> texts ++ drain_embedded()
    after
      0 -> []
    end
  end

  defp point_ids(note) do
    Repo.all(from(c in Chunk, where: c.note_id == ^note.id, select: c.qdrant_point_id),
      skip_tenant_check: true
    )
  end

  defp point(store, id), do: Agent.get(store, &Map.fetch!(&1.points, id))

  defp last_query_filter(store) do
    [body | _] = Agent.get(store, & &1.queries)
    get_in(body, ["filter", "must"]) || []
  end

  # Only the key/match conditions: the ones a filter HMAC answers.
  defp matches?(payload, conditions) do
    Enum.all?(conditions, fn
      %{"key" => key, "match" => %{"value" => v}} -> v in List.wrap(payload[key])
      %{"key" => key, "match" => %{"any" => vs}} -> Enum.any?(vs, &(&1 in List.wrap(payload[key])))
      _other -> true
    end)
  end

  defp fake_qdrant(conn, store) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
    body = if body == "", do: %{}, else: Jason.decode!(body)

    result =
      case {conn.method, conn.request_path} do
        {"PUT", "/collections/engram_notes/points"} ->
          Agent.update(store, fn s ->
            points = Map.new(body["points"], &{&1["id"], &1["payload"]})
            %{s | points: Map.merge(s.points, points), upserts: s.upserts + 1}
          end)

          %{"status" => "completed"}

        {"POST", "/collections/engram_notes/points/payload"} ->
          Agent.update(store, fn s ->
            points =
              Enum.reduce(body["points"] || [], s.points, fn id, acc ->
                Map.update(acc, id, body["payload"], &Map.merge(&1, body["payload"]))
              end)

            %{s | points: points}
          end)

          %{"status" => "completed"}

        {"POST", "/collections/engram_notes/points/scroll"} ->
          %{"points" => [], "next_page_offset" => nil}

        {"POST", "/collections/engram_notes/points/query"} ->
          Agent.update(store, &%{&1 | queries: [body | &1.queries]})
          %{"points" => []}

        _other ->
          true
      end

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"result" => result, "status" => "ok"}))
  end
end
