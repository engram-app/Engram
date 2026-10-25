defmodule Engram.Notes.NoteFieldsTest do
  @moduledoc """
  The v5 flat frontmatter fields land in Postgres (the source of truth) in
  the same indexing pass as the Qdrant payload, and the two agree.
  """
  use Engram.DataCase, async: false

  import Ecto.Query
  import Mox

  alias Engram.Crypto
  alias Engram.Crypto.DekCache
  alias Engram.Indexing
  alias Engram.Notes
  alias Engram.Notes.FrontmatterKey
  alias Engram.Notes.FrontmatterKeys
  alias Engram.Notes.Note
  alias Engram.Notes.NoteAttr
  alias Engram.Repo
  alias Engram.Vector.FilterId

  setup :verify_on_exit!

  @full """
  ---
  status: draft
  author: alice
  reviewed_by: bob
  source: [https://a, https://b]
  project: apollo
  updated: 2026-04-01T10:00:00Z
  reviewed: 2026-04-02T00:00:00Z
  expires: 2026-12-01
  due: 2026-11-01
  priority: 2
  mood: calm
  rating: 4.5
  launch: 2026-10-01
  ---
  # Fields

  Body text that yields at least one chunk.
  """

  setup do
    bypass = Bypass.open()
    Application.put_env(:engram, :qdrant_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.delete_env(:engram, :qdrant_url) end)
    Engram.ServiceConfig.put_override(:v5_payload_format, true)

    test_pid = self()

    Bypass.stub(bypass, :any, :any, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if conn.method == "PUT" and conn.request_path =~ ~r{/points$},
        do: send(test_pid, {:upsert, body})

      if conn.request_path =~ ~r{/points/payload$},
        do: send(test_pid, {:payload, conn.method, body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true, "status": "ok"}))
    end)

    user = insert(:user)
    vault = insert(:vault, user: user)
    {:ok, user: user, vault: vault}
  end

  defp index!(user, vault, content) do
    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "F/Fields.md", "content" => content, "mtime" => 1.0},
        actor: "api"
      )

    user = Repo.get!(Engram.Accounts.User, user.id)

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, prepared} = Indexing.prepare_index(note, vault, user)
    {:ok, _} = Indexing.commit_index(prepared)
    {Repo.get!(Note, note.id, skip_tenant_check: true), user}
  end

  defp attrs(note_id) do
    Repo.all(from(a in NoteAttr, where: a.note_id == ^note_id), skip_tenant_check: true)
  end

  defp named(field), do: FrontmatterKeys.named_id(field)

  # Qdrant's keyword `match` semantics on one payload: `value` matches a
  # scalar or any element of a list, `any` matches if one of them does.
  defp payload_matches?(p, %{key: k, match: %{value: v}}), do: v in List.wrap(p[k])

  defp payload_matches?(p, %{key: k, match: %{any: vs}}),
    do: Enum.any?(vs, &(&1 in List.wrap(p[k])))

  defp dictionary(user_id),
    do:
      Repo.all(from(k in FrontmatterKey, where: k.user_id == ^user_id, order_by: k.key_id),
        skip_tenant_check: true
      )

  # key_hmac -> key_id for this user's user-added keys.
  defp ids(user_id), do: Map.new(dictionary(user_id), &{&1.key_hmac, &1.key_id})

  # 2026-10-20 Postgres scale audit: no frontmatter field lives on `notes`.
  test "notes carries no flat-field columns" do
    cols =
      Repo.query!("SELECT column_name FROM information_schema.columns WHERE table_name = 'notes'").rows
      |> List.flatten()

    for c <- ~w(status_hmac status_ciphertext author_hmac rev_by_hmac src_hmac proj_hmac
                fm_updated fm_reviewed fm_expires fm_due fm_priority),
        do: refute(c in cols, c)
  end

  # The pass writes note_attrs without moving vaults.change_seq, so the field
  # catalog (cached on that seq) must be evicted by the pass itself.
  test "an index pass evicts the vault's field catalog", %{user: user, vault: vault} do
    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "F/Fields.md", "content" => @full, "mtime" => 1.0},
        actor: "api"
      )

    user = Repo.get!(Engram.Accounts.User, user.id)
    assert {:ok, []} = Engram.Notes.FieldCatalog.list(user, vault)

    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    {:ok, prepared} = Indexing.prepare_index(note, vault, user)
    {:ok, _} = Indexing.commit_index(prepared)

    assert {:ok, fields} = Engram.Notes.FieldCatalog.list(user, vault)
    assert "mood" in Enum.map(fields, & &1.name)
  end

  test "named fields land in note_attrs under their reserved ids", %{user: user, vault: vault} do
    {note, user} = index!(user, vault, @full)
    {:ok, fk} = Crypto.dek_filter_key(user)
    rows = attrs(note.id)

    assert Enum.all?(rows, &(&1.user_id == user.id and &1.vault_id == vault.id))

    h = fn field -> for r <- rows, r.key_id == named(field), do: r.h end
    d = fn field -> for r <- rows, r.key_id == named(field), do: r.d end

    assert h.(:status) == [FilterId.value_hmac(fk, "draft")]
    assert h.(:author) == [FilterId.value_hmac(fk, "alice")]
    assert h.(:reviewed_by) == [FilterId.value_hmac(fk, "bob")]
    assert h.(:project) == [FilterId.value_hmac(fk, "apollo")]

    assert Enum.sort(h.(:source)) ==
             Enum.sort([
               FilterId.value_hmac(fk, "https://a"),
               FilterId.value_hmac(fk, "https://b")
             ])

    assert d.(:updated) == [DateTime.to_unix(~U[2026-04-01 10:00:00Z])]
    assert d.(:reviewed) == [DateTime.to_unix(~U[2026-04-02 00:00:00Z])]
    assert d.(:expires) == [DateTime.to_unix(~U[2026-12-01 00:00:00Z])]
    assert d.(:due) == [DateTime.to_unix(~U[2026-11-01 00:00:00Z])]
    assert for(r <- rows, r.key_id == named(:priority), do: r.n) == [2.0]
  end

  # A pass used to fetch the DEK again for the user-added key ids and swallow
  # any error there. A reload that timed out (a stalled loader holding the
  # claim) and then filled in time for the next fetch committed the note
  # WITHOUT its user-added keys, with payload_hash stamped, so it never healed.
  # The pass now fetches the DEK once for its keys, and a later fetch that
  # fails fails the pass rather than leaving it half-built.
  test "a DEK reload stalled mid-pass does not drop the user-added keys",
       %{user: user, vault: vault} do
    {:ok, note} =
      Notes.upsert_note(
        user,
        vault,
        %{"path" => "F/Fields.md", "content" => @full, "mtime" => 1.0},
        actor: "api"
      )

    user = Repo.get!(Engram.Accounts.User, user.id)
    {:ok, dek} = Crypto.get_dek(user)
    pass = self()
    on_exit(fn -> :telemetry.detach("stalled-reload") end)

    # Mid-pass (the embed call), evict the DEK and have another process hold
    # the reload claim. The first miss after that times out; the second finds
    # the loader's DEK.
    stub(Engram.MockEmbedder, :embed_texts, fn texts ->
      token = Engram.StalledDekLoad.stall!(user.id)
      Process.put(:dek_misses, 0)

      :telemetry.attach(
        "stalled-reload",
        [:engram, :crypto, :dek_cache],
        fn _, _, meta, _ ->
          if self() == pass and meta.outcome == :miss do
            before = Process.put(:dek_misses, Process.get(:dek_misses) + 1)
            if before == 1, do: :ok = DekCache.put_if_claimed(user.id, token, dek)
          end
        end,
        nil
      )

      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    # Either outcome is fine but one: a committed, stamped pass without the key.
    case Indexing.prepare_index(note, vault, user) do
      {:ok, prepared} ->
        {:ok, _} = Indexing.commit_index(prepared)
        {:ok, fk} = Crypto.dek_filter_key(user)
        mood = ids(user.id)[FilterId.key_hmac(fk, "mood")]
        assert mood, "the pass committed without an id for the user-added key"
        assert Enum.any?(attrs(note.id), &(&1.key_id == mood))

      {:error, :dek_load_timeout} ->
        assert attrs(note.id) == []
        assert is_nil(Repo.get!(Note, note.id, skip_tenant_check: true).payload_hash)
    end
  end

  test "user-added keys get dictionary ids; numbers and dates stay plaintext",
       %{user: user, vault: vault} do
    {note, user} = index!(user, vault, @full)
    {:ok, fk} = Crypto.dek_filter_key(user)
    {:ok, dek} = Crypto.get_dek(user)
    ids = ids(user.id)
    by_id = for r <- attrs(note.id), r.key_id >= 64, into: %{}, do: {r.key_id, r}

    mood = ids[FilterId.key_hmac(fk, "mood")]
    assert by_id[mood].h == FilterId.value_hmac(fk, "calm")
    assert by_id[ids[FilterId.key_hmac(fk, "rating")]].n == 4.5

    assert by_id[ids[FilterId.key_hmac(fk, "launch")]].d ==
             DateTime.to_unix(~U[2026-10-01 00:00:00Z])

    assert map_size(by_id) == 3

    # The dictionary holds the key only as an HMAC plus the encrypted name.
    names = for k <- dictionary(user.id), do: elem(FrontmatterKeys.name(k, dek), 1)
    assert Enum.sort(names) == ~w(launch mood rating)
  end

  test "past the key cap a new key is skipped, never an error", %{user: user, vault: vault} do
    Engram.ServiceConfig.put_override(:frontmatter_key_cap, 2)
    {note, _user} = index!(user, vault, @full)

    assert length(dictionary(user.id)) == 2
    assert length(for r <- attrs(note.id), r.key_id >= 64, do: r) == 2
  end

  # N1: an id resolved before the Voyage call may be reaped before commit.
  describe "a reaper racing an index pass" do
    defp age_keys!(user_id) do
      Repo.query!(
        "UPDATE frontmatter_keys SET inserted_at = now() - interval '2 days' WHERE user_id = $1",
        [Ecto.UUID.dump!(user_id)]
      )
    end

    # `phase` used, then unused, aged, and not the user's highest id.
    defp reapable_phase!(user, vault) do
      {_note, user} = index!(user, vault, "---\nphase: beta\n---\n# Fields\n\nBody one.\n")
      {:ok, fk} = Crypto.dek_filter_key(user)
      {:ok, dek} = Crypto.get_dek(user)

      {_, 0} =
        FrontmatterKeys.resolve(user.id, dek, %{FilterId.key_hmac(fk, "zz_top") => "zz_top"})

      {_note, user} = index!(user, vault, "# Fields\n\nBody two.\n")
      age_keys!(user.id)
      phase = ids(user.id)[FilterId.key_hmac(fk, "phase")]
      {user, fk, phase}
    end

    defp dangling(user_id, note_id) do
      known = user_id |> dictionary() |> MapSet.new(& &1.key_id)
      for r <- attrs(note_id), r.key_id >= 64, not MapSet.member?(known, r.key_id), do: r.key_id
    end

    test "commit refuses an id reaped after it was resolved", %{user: user, vault: vault} do
      {user, _fk, phase} = reapable_phase!(user, vault)

      {:ok, note} =
        Notes.upsert_note(
          user,
          vault,
          %{"path" => "F/Fields.md", "content" => "---\nphase: beta\n---\n# F\n\nBody three.\n"},
          actor: "api"
        )

      {:ok, prepared} = Indexing.prepare_index(note, vault, user)
      assert FrontmatterKeys.reap_unused() >= 1
      refute phase in Enum.map(dictionary(user.id), & &1.key_id)

      assert Indexing.commit_index(prepared) == {:error, :frontmatter_keys_gone}
    end

    test "the pass re-resolves once and never writes a dead id", %{user: user, vault: vault} do
      {user, fk, phase} = reapable_phase!(user, vault)

      # The reaper runs while the pass is embedding, i.e. after `resolve`.
      stub(Engram.MockEmbedder, :embed_texts, fn texts ->
        _ = FrontmatterKeys.reap_unused()
        {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
      end)

      {:ok, note} =
        Notes.upsert_note(
          user,
          vault,
          %{"path" => "F/Fields.md", "content" => "---\nphase: beta\n---\n# F\n\nBody four.\n"},
          actor: "api"
        )

      assert {:ok, _, _, _} = Indexing.index_note_with_usage(note, vault, user)

      new_phase = ids(user.id)[FilterId.key_hmac(fk, "phase")]
      assert new_phase > phase
      assert dangling(user.id, note.id) == []
      assert Enum.any?(attrs(note.id), &(&1.key_id == new_phase))
    end
  end

  test "an absent key writes no row", %{user: user, vault: vault} do
    {note, _user} = index!(user, vault, "# Plain\n\nBody text with no frontmatter.\n")
    assert attrs(note.id) == []
  end

  test "removing a key removes its rows", %{user: user, vault: vault} do
    {note, _user} = index!(user, vault, @full)
    assert Enum.any?(attrs(note.id), &(&1.key_id == named(:status)))

    {note, _user} = index!(user, vault, "---\nauthor: alice\n---\n# Fields\n\nBody text again.\n")
    assert Enum.map(attrs(note.id), & &1.key_id) == [named(:author)]
  end

  test "with the v5 format off, a pass writes nothing new to Postgres", %{
    user: user,
    vault: vault
  } do
    Engram.ServiceConfig.put_override(:v5_payload_format, false)
    {note, _user} = index!(user, vault, @full)
    assert attrs(note.id) == []
    assert dictionary(user.id) == []
  end

  describe "Postgres and the v5 Qdrant payload agree" do
    setup do
      Application.put_env(:engram, :write_v5_layout, true)
      on_exit(fn -> Application.delete_env(:engram, :write_v5_layout) end)
    end

    # YAML reads `status: 2` as a number and `reviewed_by: true` as a
    # boolean; a named exact field must still hold their text, or a filter
    # for "2" finds nothing. Date-shaped strings stay text too.
    test "numbers, booleans and date-shaped values on named exact fields match as text",
         %{user: user, vault: vault} do
      content = """
      ---
      type: 2026-01-01
      status: 2
      author: 42
      reviewed_by: true
      project: 2026-01-01
      source: [2024, 1.5, https://a]
      ---
      # Fields

      Body text that yields at least one chunk.
      """

      {note, user} = index!(user, vault, content)
      {:ok, fk} = Crypto.dek_filter_key(user)
      rows = attrs(note.id)
      h = fn field -> for r <- rows, r.key_id == named(field), do: r.h end
      v = &FilterId.value_hmac(fk, &1)

      assert note.type_hmac == Crypto.hmac_field(fk, "2026-01-01")
      assert h.(:status) == [v.("2")]
      assert h.(:author) == [v.("42")]
      assert h.(:reviewed_by) == [v.("true")]
      assert h.(:project) == [v.("2026-01-01")]
      assert Enum.sort(h.(:source)) == Enum.sort([v.("2024"), v.("1.5"), v.("https://a")])

      assert_received {:upsert, body}
      %{"points" => [%{"payload" => p} | _]} = Jason.decode!(body)

      for {key, value} <- [
            {"status", "2"},
            {"status", 2},
            {"author", "42"},
            {"reviewed_by", true},
            {"project", "2026-01-01"},
            {"source", "2024"},
            {"source", 1.5}
          ] do
        assert {:ok, [c]} =
                 Engram.Search.FieldFilters.to_conditions(user.id, fk, [
                   %{"key" => key, "value" => value}
                 ])

        assert payload_matches?(p, c), "#{key} #{inspect(value)}"
      end
    end

    test "field for field", %{user: user, vault: vault} do
      {note, user} = index!(user, vault, @full)
      {:ok, fk} = Crypto.dek_filter_key(user)
      assert_received {:upsert, body}
      %{"points" => [%{"payload" => p, "id" => id} | _]} = Jason.decode!(body)
      rows = attrs(note.id)
      one = fn field -> Enum.find(rows, &(&1.key_id == named(field))) end

      assert p["s"] == FilterId.from_hmac(one.(:status).h)
      assert p["a"] == FilterId.from_hmac(one.(:author).h)
      assert p["r"] == FilterId.from_hmac(one.(:reviewed_by).h)
      assert p["j"] == FilterId.from_hmac(one.(:project).h)
      assert p["up"] == one.(:updated).d
      assert p["rd"] == one.(:reviewed).d
      assert p["ex"] == div(one.(:expires).d, 86_400)
      assert p["du"] == div(one.(:due).d, 86_400)
      assert p["pr"] == one.(:priority).n
      assert p["u"] == FilterId.uuid(note.user_id)

      # `fa` mirrors the user-key rows: same key id, same value.
      user_rows = for r <- rows, r.key_id >= 64, do: r

      expected =
        for r <- user_rows do
          cond do
            r.h -> %{"k" => r.key_id, "h" => FilterId.from_hmac(r.h)}
            r.n -> %{"k" => r.key_id, "n" => r.n}
            r.d -> %{"k" => r.key_id, "d" => r.d}
          end
        end

      assert Enum.sort(p["fa"]) == Enum.sort(expected)
      refute Map.has_key?(p, "at") or Map.has_key?(p, "nm") or Map.has_key?(p, "dt")
      # No key name or key HMAC in the payload: only small integer ids.
      for %{"k" => k} <- p["fa"], do: assert(is_integer(k))
      refute inspect(p) =~ FilterId.attr(fk, "mood")

      assert String.at(id, 14) == "5"
      refute Map.has_key?(p, "text")
    end

    # Review H2: a reused point is refreshed by REPLACING its payload, so a key
    # removed from the frontmatter (or a move to the root) leaves no stale key.
    test "a removed key disappears from a reused point", %{user: user, vault: vault} do
      body = "\n# Fields\n\nBody text that yields at least one chunk.\n"
      {_note, _user} = index!(user, vault, "---\nstatus: draft\ndue: 2026-11-01\n---" <> body)
      {_note, _user} = index!(user, vault, "---\ndue: 2026-11-01\n---" <> body)

      assert_received {:payload, "PUT", refresh}
      refute_received {:payload, "POST", _}
      payload = Jason.decode!(refresh)["payload"]
      refute Map.has_key?(payload, "s")
      assert Map.has_key?(payload, "du")
    end

    test "deterministic ids, no text", %{user: user, vault: vault} do
      {_note, _user} = index!(user, vault, @full)
      assert_received {:upsert, body}
      %{"points" => [%{"payload" => p, "id" => id} | _]} = Jason.decode!(body)
      assert String.at(id, 14) == "5"
      refute Map.has_key?(p, "text")
    end
  end
end
