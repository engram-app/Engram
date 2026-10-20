defmodule Engram.Search.FieldFiltersTest do
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Notes.FrontmatterKeys
  alias Engram.Search.FieldFilters
  alias Engram.Vector.FilterId
  alias Engram.Vector.Qdrant

  setup do
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
    assert d == Qdrant.attr_filter(ctx.id.("launch"), {:d, gte: day, lte: day + 86_399})
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

  test "an unknown key is an explicit error, never an empty result", ctx do
    assert run(ctx, [%{"key" => "phase", "value" => "x"}, %{"key" => "nope", "value" => 1}]) ==
             {:error, {:unknown_field, "nope"}}
  end

  test "a named field is reserved; a bad op or value is invalid", ctx do
    assert run(ctx, [%{"key" => "Status", "value" => "draft"}]) ==
             {:error, {:reserved_field, "Status"}}

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
