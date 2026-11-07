defmodule Engram.Search.FieldFiltersTest do
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Notes.FrontmatterKeys
  alias Engram.Search.FieldFilters
  alias Engram.Vector.FilterId

  setup do
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, fk} = Crypto.dek_filter_key(user)
    names = Map.new(~w(Phase rating launch), &{FilterId.key_hmac(fk, &1), &1})
    {ids, 0} = FrontmatterKeys.resolve(user.id, dek, names)
    id = fn key -> ids[FilterId.key_hmac(fk, key)] end
    %{user: user, fk: fk, id: id}
  end

  # The parsed specs Postgres resolves (`Engram.Search.NoteFilter`, R3a: no
  # Qdrant condition is built from them any more).
  defp run(ctx, filters), do: FieldFilters.to_specs(ctx.user.id, ctx.fk, filters)

  defp h(ctx, v), do: FilterId.value_hmac(ctx.fk, v)

  # `in: []` names no value, so it is a bad filter, never a match-nothing one.
  test "in with an empty list is an invalid filter", ctx do
    for key <- ~w(type tags status phase) do
      assert run(ctx, [%{"key" => key, "op" => "in", "value" => []}]) ==
               {:error, {:invalid_field_filter, key}}
    end
  end

  test "eq on a string is an exact match on its value hmac, key case-insensitive", ctx do
    assert run(ctx, [%{"key" => "phase", "op" => "eq", "value" => "Draft"}]) ==
             {:ok, [{:h, nil, ctx.id.("phase"), h(ctx, "draft")}]}
  end

  test "numbers compare n; dates compare d; a bare-date eq is that UTC day", ctx do
    day = DateTime.to_unix(~U[2026-11-01 00:00:00Z])

    assert {:ok, [n, d, after_, between]} =
             run(ctx, [
               %{"key" => "rating", "op" => "gte", "value" => 4},
               %{"key" => "launch", "value" => "2026-11-01"},
               %{"key" => "launch", "op" => "after", "value" => "2026-11-01"},
               %{"key" => "rating", "op" => "eq", "value" => 4.5}
             ])

    assert n == {:range, nil, ctx.id.("rating"), :n, %{gte: 4}}
    assert d == {:range, nil, ctx.id.("launch"), :d, %{gte: day, lt: day + 86_400}}
    assert after_ == {:range, nil, ctx.id.("launch"), :d, %{gte: day}}
    assert between == {:range, nil, ctx.id.("rating"), :n, %{gte: 4.5, lte: 4.5}}
  end

  test "in over strings is one any-match; a mixed in is an any of specs", ctx do
    assert run(ctx, [%{"key" => "phase", "op" => "in", "value" => ["a", "b"]}]) ==
             {:ok, [{:h, nil, ctx.id.("phase"), [h(ctx, "a"), h(ctx, "b")]}]}

    assert {:ok, [{:any, [_, _]}]} =
             run(ctx, [%{"key" => "rating", "op" => "in", "value" => [3, "x"]}])
  end

  # H1: every named field (and alias) routes to its named key.
  describe "named fields" do
    defp one(ctx, filter) do
      {:ok, [c]} = run(ctx, [filter])
      c
    end

    test "exact strings: status, author, reviewed_by, project, source (+ aliases)", ctx do
      for {key, field} <- [
            {"author", :author_id},
            {"reviewed_by", :rev_by_id},
            {"Project", :proj_id},
            {"source", :src_id},
            {"resource", :src_id},
            {"sources", :src_id}
          ] do
        assert {:h, ^field, _id, [hmac]} = one(ctx, %{"key" => key, "value" => "Draft"}), key
        assert hmac == h(ctx, "draft"), key
      end

      assert {:h, :author_id, _, [a, b]} =
               one(ctx, %{"key" => "author", "op" => "in", "value" => ["a", "b"]})

      assert [a, b] == [h(ctx, "a"), h(ctx, "b")]
    end

    # A named exact field stores every string as a value HMAC, date-shaped
    # ones too (a `project: 2026-01-01`), so the filter must match them as
    # text; the field catalog lists such values.
    test "a date-shaped string on a named exact field is an exact match", ctx do
      assert {:h, :proj_id, _, [hmac]} = one(ctx, %{"key" => "project", "value" => "2026-01-01"})
      assert hmac == h(ctx, "2026-01-01")
    end

    test "status stable is the default", ctx do
      assert {:status, true, []} = one(ctx, %{"key" => "status", "value" => "Stable"})

      assert {:status, true, [_draft]} =
               one(ctx, %{"key" => "status", "op" => "in", "value" => ["stable", "draft"]})
    end

    test "a named key folds NFKC + case and takes its localized names", ctx do
      want = one(ctx, %{"key" => "type", "value" => "会議"})

      for key <- ["Type", "ｔｙｐｅ", "種類"] do
        assert one(ctx, %{"key" => key, "value" => "会議"}) == want, key
      end

      assert one(ctx, %{"key" => "ＳＴＡＴＵＳ", "value" => "draft"}) ==
               one(ctx, %{"key" => "status", "value" => "draft"})

      assert run(ctx, [%{"key" => "Beschreibung", "value" => "x"}]) ==
               {:error, {:reserved_field, "Beschreibung"}}
    end

    test "dates in seconds: created (date), updated (timestamp, modified), reviewed", ctx do
      day = DateTime.to_unix(~U[2026-11-01 00:00:00Z])

      for {key, field} <- [
            {"created", :fm_created},
            {"date", :fm_created},
            {"updated", :fm_timestamp},
            {"timestamp", :fm_timestamp},
            {"modified", :fm_timestamp},
            {"reviewed", :fm_reviewed}
          ] do
        assert {:range, ^field, _id, :d, %{gte: ^day}} =
                 one(ctx, %{"key" => key, "op" => "after", "value" => "2026-11-01"}),
               key
      end
    end

    test "expires (stale_after) and due bound whole days", ctx do
      d = DateTime.to_unix(~U[2026-11-01 00:00:00Z])

      for {key, field} <- [
            {"expires", :fm_expires},
            {"stale_after", :fm_expires},
            {"due", :fm_due}
          ] do
        assert {:range, ^field, _, :d, %{lt: ^d}} =
                 one(ctx, %{"key" => key, "op" => "before", "value" => "2026-11-01"})

        assert {:range, ^field, _, :d, range} = one(ctx, %{"key" => key, "value" => "2026-11-01"})
        assert range == %{gte: d, lt: d + 86_400}
      end
    end

    test "priority ranges as a number", ctx do
      assert {:range, :fm_priority, _, _, %{gte: 2}} =
               one(ctx, %{"key" => "priority", "op" => "gte", "value" => 2})

      assert run(ctx, [%{"key" => "priority", "value" => "high"}]) ==
               {:error, {:invalid_field_filter, "priority"}}
    end

    test "named fields need no dictionary query", ctx do
      ref = make_ref()
      pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:engram, :repo, :query],
        fn _e, _m, meta, _ -> if meta[:source] == "frontmatter_keys", do: send(pid, ref) end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

      {:ok, [_, _]} =
        run(ctx, [
          %{"key" => "status", "value" => "x"},
          %{"key" => "due", "op" => "after", "value" => "2026-01-01"}
        ])

      refute_received ^ref
    end
  end

  test "date bounds: a bare date is the whole UTC day", ctx do
    d = DateTime.to_unix(~U[2026-11-01 00:00:00Z])

    r = fn op ->
      elem(run(ctx, [%{"key" => "launch", "op" => op, "value" => "2026-11-01"}]), 1)
    end

    range = fn [{:range, nil, _id, :d, range}] -> range end

    assert range.(r.("before")) == %{lt: d}
    assert range.(r.("after")) == %{gte: d}
    assert range.(r.("gt")) == %{gte: d + 86_400}
    assert range.(r.("lte")) == %{lt: d + 86_400}
  end

  test "an `in` list is capped at 100; filters at 16", ctx do
    assert run(ctx, [%{"key" => "phase", "op" => "in", "value" => Enum.map(1..101, &"v#{&1}")}]) ==
             {:error, {:invalid_field_filter, "phase"}}

    assert run(ctx, List.duplicate(%{"key" => "phase", "value" => "x"}, 17)) ==
             {:error, {:too_many_field_filters, 16}}
  end

  test "a huge integer is invalid", ctx do
    assert run(ctx, [%{"key" => "rating", "op" => "gt", "value" => 10 ** 400}]) ==
             {:error, {:invalid_field_filter, "rating"}}
  end

  test "an echoed key is capped at 64 chars", ctx do
    long = String.duplicate("k", 500)
    assert {:error, {:unknown_field, echo}} = run(ctx, [%{"key" => long, "value" => "x"}])
    assert String.length(echo) == 64
  end

  test "a missing key at the field limit is not indexed, not unknown", ctx do
    Engram.ServiceConfig.put_override(:frontmatter_key_cap, 3)

    assert run(ctx, [%{"key" => "skipped", "value" => "x"}]) ==
             {:error, {:field_not_indexed, "skipped"}}
  end

  describe "Search.search/4" do
    setup ctx do
      %{vault: insert(:vault, user: ctx.user)}
    end

    defp search(ctx),
      do:
        Engram.Search.search(ctx.user, ctx.vault, "q", fields: [%{"key" => "nope", "value" => 1}])

    test "the key is resolved (unknown here), before any search runs", ctx do
      assert search(ctx) == {:error, {:unknown_field, "nope"}}
    end

    test "every error has a caller-facing message" do
      for reason <- [
            {:unknown_field, "k"},
            {:field_not_indexed, "k"},
            {:reserved_field, "k"},
            {:invalid_field_filter, "k"},
            {:too_many_field_filters, 16}
          ],
          do: assert(is_binary(Engram.Search.input_error_message(reason)), inspect(reason))
    end
  end

  test "an unknown key is an explicit error, never an empty result", ctx do
    assert run(ctx, [%{"key" => "phase", "value" => "x"}, %{"key" => "nope", "value" => 1}]) ==
             {:error, {:unknown_field, "nope"}}
  end

  test "unfilterable keys are reserved; a bad op or value is invalid", ctx do
    assert run(ctx, [%{"key" => "Title", "value" => "x"}]) ==
             {:error, {:reserved_field, "Title"}}

    assert run(ctx, [%{"key" => "phase", "op" => "like", "value" => "x"}]) ==
             {:error, {:invalid_field_filter, "phase"}}

    assert run(ctx, [%{"key" => "rating", "op" => "gt", "value" => "high"}]) ==
             {:error, {:invalid_field_filter, "rating"}}
  end

  test "every key name resolves in ONE dictionary query", ctx do
    ref = make_ref()
    pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:engram, :repo, :query],
      fn _e, _m, meta, _ -> if meta[:source] == "frontmatter_keys", do: send(pid, {ref, :q}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    {:ok, [_, _, _]} =
      run(ctx, [
        %{"key" => "phase", "value" => "x"},
        %{"key" => "rating", "op" => "lt", "value" => 9},
        %{"key" => "launch", "op" => "before", "value" => "2027-01-01"}
      ])

    assert_received {^ref, :q}
    refute_received {^ref, :q}
  end
end
