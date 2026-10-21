defmodule Engram.Search.FieldFiltersTest do
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Notes.FrontmatterKeys
  alias Engram.Search.FieldFilters
  alias Engram.Vector.FilterId
  alias Engram.Vector.Qdrant

  setup do
    Engram.ServiceConfig.put_override(:v5_payload_format, true)
    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    {:ok, dek} = Crypto.get_dek(user)
    {:ok, fk} = Crypto.dek_filter_key(user)
    names = Map.new(~w(Phase rating launch), &{FilterId.key_hmac(fk, &1), &1})
    {ids, 0} = FrontmatterKeys.resolve(user.id, dek, names)
    id = fn key -> ids[FilterId.key_hmac(fk, key)] end
    %{user: user, fk: fk, id: id}
  end

  defp run(ctx, filters), do: FieldFilters.to_conditions(ctx.user.id, ctx.fk, filters)

  test "eq on a string is an exact match on its value id, key case-insensitive", ctx do
    assert run(ctx, [%{"key" => "phase", "op" => "eq", "value" => "Draft"}]) ==
             {:ok,
              [Qdrant.attr_filter(ctx.id.("phase"), {:h, FilterId.attr_value(ctx.fk, "draft")})]}
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

    assert n == Qdrant.attr_filter(ctx.id.("rating"), {:n, gte: 4})
    assert d == Qdrant.attr_filter(ctx.id.("launch"), {:d, gte: day, lt: day + 86_400})
    assert after_ == Qdrant.attr_filter(ctx.id.("launch"), {:d, gte: day})
    assert between == Qdrant.attr_filter(ctx.id.("rating"), {:n, gte: 4.5, lte: 4.5})
  end

  test "in over strings is one any-match; a mixed in is a should", ctx do
    v = &FilterId.attr_value(ctx.fk, &1)

    assert run(ctx, [%{"key" => "phase", "op" => "in", "value" => ["a", "b"]}]) ==
             {:ok, [Qdrant.attr_filter(ctx.id.("phase"), {:h, [v.("a"), v.("b")]})]}

    assert {:ok, [%{should: [_, _]}]} =
             run(ctx, [%{"key" => "rating", "op" => "in", "value" => [3, "x"]}])
  end

  # H1: every named field (and alias) routes to the payload key v5 writes.
  describe "named fields" do
    defp one(ctx, filter) do
      {:ok, [c]} = run(ctx, [filter])
      c
    end

    defp v5(%{should: [_legacy, v5]}), do: v5
    defp v5(c), do: c

    test "exact strings: status, author, reviewed_by, project, source (+ aliases)", ctx do
      v = &FilterId.attr_value(ctx.fk, &1)

      for {key, short} <- [
            {"status", "s"},
            {"author", "a"},
            {"reviewed_by", "r"},
            {"Project", "j"},
            {"source", "o"},
            {"resource", "o"},
            {"sources", "o"}
          ] do
        assert one(ctx, %{"key" => key, "value" => "Draft"}) ==
                 %{key: short, match: %{value: v.("draft")}},
               key
      end

      assert one(ctx, %{"key" => "author", "op" => "in", "value" => ["a", "b"]}) ==
               %{key: "a", match: %{any: [v.("a"), v.("b")]}}
    end

    test "status stable is the default: it matches a missing s", ctx do
      assert one(ctx, %{"key" => "status", "value" => "Stable"}) == %{is_empty: %{key: "s"}}

      assert %{should: [%{is_empty: %{key: "s"}}, %{key: "s"}]} =
               one(ctx, %{"key" => "status", "op" => "in", "value" => ["stable", "draft"]})
    end

    test "type and tags use the row blind indexes, both formats", ctx do
      type = Base.encode64(Engram.Crypto.hmac_field(ctx.fk, "playbook"))

      assert one(ctx, %{"key" => "type", "value" => "Playbook"}) ==
               Qdrant.match_filter(:type, type)

      tag = Base.encode64(Engram.Crypto.hmac_field(ctx.fk, "ops"))
      assert one(ctx, %{"key" => "tags", "value" => "ops"}) == Qdrant.match_filter(:tags, [tag])
    end

    test "dates in seconds: created (date), updated (timestamp, modified), reviewed", ctx do
      day = DateTime.to_unix(~U[2026-11-01 00:00:00Z])

      for {key, short} <- [
            {"created", "cr"},
            {"date", "cr"},
            {"updated", "up"},
            {"timestamp", "up"},
            {"modified", "up"},
            {"reviewed", "rd"}
          ] do
        assert %{key: ^short, range: %{gte: ^day}} =
                 v5(one(ctx, %{"key" => key, "op" => "after", "value" => "2026-11-01"})),
               key
      end
    end

    test "expires (stale_after) and due compare day numbers", ctx do
      d = div(DateTime.to_unix(~U[2026-11-01 00:00:00Z]), 86_400)

      for {key, short} <- [{"expires", "ex"}, {"stale_after", "ex"}, {"due", "du"}] do
        assert one(ctx, %{"key" => key, "op" => "before", "value" => "2026-11-01"}) ==
                 %{key: short, range: %{lt: d}}

        assert one(ctx, %{"key" => key, "value" => "2026-11-01"}) ==
                 %{key: short, range: %{gte: d, lt: d + 1}}
      end
    end

    test "priority ranges as a number", ctx do
      assert one(ctx, %{"key" => "priority", "op" => "gte", "value" => 2}) ==
               %{key: "pr", range: %{gte: 2}}

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

    range = fn [%{nested: %{filter: %{must: [_, %{range: range}]}}}] -> range end

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

  test "a huge integer is invalid, not a Qdrant 400", ctx do
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

  # M1: one accessor gates `fields` on the v5 format AND the v5 layout.
  describe "Search.search/4 gate" do
    setup ctx do
      %{vault: insert(:vault, user: ctx.user)}
    end

    defp search(ctx),
      do:
        Engram.Search.search(ctx.user, ctx.vault, "q", fields: [%{"key" => "nope", "value" => 1}])

    test "format and layout off: unavailable, not unknown", ctx do
      Engram.ServiceConfig.put_override(:v5_payload_format, false)
      Engram.ServiceConfig.put_override(:write_v5_layout, false)
      refute FieldFilters.available?()
      assert search(ctx) == {:error, :field_filters_unavailable}
    end

    test "format on, layout off: unavailable (v3 points carry no fa)", ctx do
      Engram.ServiceConfig.put_override(:write_v5_layout, false)
      refute FieldFilters.available?()
      assert search(ctx) == {:error, :field_filters_unavailable}
    end

    test "both on: the key is resolved (unknown here), before any search runs", ctx do
      Engram.ServiceConfig.put_override(:write_v5_layout, true)
      assert FieldFilters.available?()
      assert search(ctx) == {:error, {:unknown_field, "nope"}}
    end

    test "every error has a caller-facing message" do
      for reason <- [
            :field_filters_unavailable,
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
