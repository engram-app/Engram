defmodule Engram.RepoTenantSpanNamingTest do
  @moduledoc """
  `Repo.with_tenant/2`'s own SQL must carry a `:source` so its spans are named.

  `opentelemetry_ecto` builds the span name as
  `span_prefix <> if(source, do: ":\#{source}", else: "")` — there is no
  per-query naming hook, so an absent `:source` yields a bare
  `engram.repo.query` span. The RLS block issues four such statements per
  invocation (begin, set tenant+role, reset role, commit), none of which is
  schema-backed, so before this they were all anonymous.

  That mattered in practice: a 2026-08-02 trace audit found 3,069 of 5,389
  repo.query spans unnamed over 23h, and reading them as "Oban noise" was the
  first wrong guess. They were RLS plumbing on the hot request path — 13 per
  `GET /api/sync/manifest`, 7.9ms of query time against 5.1ms for the actual
  data queries.

  `source` for a raw query is plain `Keyword.get(opts, :source)` in
  `Ecto.Adapters.SQL.log/5`, and transaction opts reach the same call for
  begin/commit via `checkout_or_transaction/4`.
  """
  use Engram.DataCase, async: false

  @event [:engram, :repo, :query]

  setup do
    parent = self()
    ref = make_ref()

    :telemetry.attach(
      {__MODULE__, ref},
      @event,
      fn _event, _measurements, metadata, _cfg ->
        send(parent, {ref, metadata.source, to_string(metadata.query)})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    %{ref: ref}
  end

  defp drain(ref, acc \\ []) do
    receive do
      {^ref, source, query} -> drain(ref, [{source, query} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "with_tenant/2 span naming" do
    test "every statement the RLS block issues carries a source", %{ref: ref} do
      user = insert(:user)

      {:ok, :ok} = Repo.with_tenant(user.id, fn -> :ok end)

      events = drain(ref)
      assert events != [], "expected with_tenant to emit repo.query telemetry"

      unnamed = for {nil, query} <- events, do: query

      assert unnamed == [],
             """
             with_tenant emitted statements with no :source, which render as
             bare `engram.repo.query` spans in Tempo:

             #{Enum.map_join(unnamed, "\n", &("  - " <> &1))}
             """
    end

    test "the sources are the RLS ones, not a schema table", %{ref: ref} do
      user = insert(:user)

      {:ok, :ok} = Repo.with_tenant(user.id, fn -> :ok end)

      sources = ref |> drain() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

      # Sandbox runs the block as a savepoint, so begin/commit may surface as
      # savepoint statements or be absent entirely — assert on the two
      # set_config statements we always issue ourselves, and that whatever
      # else fires is still named.
      assert "tenant_enter" in sources
      assert "tenant_exit" in sources
      refute nil in sources
    end

    test "a nested same-tenant call adds no extra RLS statements", %{ref: ref} do
      user = insert(:user)

      {:ok, :ok} =
        Repo.with_tenant(user.id, fn ->
          {:ok, :ok} = Repo.with_tenant(user.id, fn -> :ok end)
          :ok
        end)

      sources = ref |> drain() |> Enum.map(&elem(&1, 0))

      # Re-entrancy is what makes collapsing call sites cheap — if this ever
      # regresses, every nested call starts paying four round trips again.
      assert Enum.count(sources, &(&1 == "tenant_enter")) == 1
      assert Enum.count(sources, &(&1 == "tenant_exit")) == 1
    end
  end
end
