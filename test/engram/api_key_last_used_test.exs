defmodule Engram.ApiKeyLastUsedTest do
  # api_keys.last_used is shown on the connections page and the auth
  # response, but nothing wrote it, so it was always null. Authentication now
  # stamps it, at most once an hour per key, so it never costs a write per
  # request.
  use Engram.DataCase, async: false

  alias Engram.Accounts
  alias Engram.Accounts.ApiKey
  alias Engram.QueryRecorder

  setup do
    user = insert(:user)
    {:ok, raw, key} = Accounts.create_api_key(user, "k")
    Engram.Cache.clear_local(:api_key_used)
    %{raw: raw, key: key, user: user}
  end

  defp last_used(key) do
    Repo.with_tenant!(key.user_id, fn -> Repo.get!(ApiKey, key.id).last_used end)
  end

  defp key_writes(fun) do
    {_, qs} = QueryRecorder.record(fun)
    Enum.filter(qs, &(&1.sql =~ ~r/^UPDATE "api_keys"/))
  end

  test "authenticating stamps last_used", %{raw: raw, key: key} do
    assert is_nil(last_used(key))
    assert {:ok, _user, _key} = Accounts.validate_api_key(raw)
    assert %DateTime{} = last_used(key)
  end

  test "a second request within the hour writes nothing", %{raw: raw} do
    {:ok, _, _} = Accounts.validate_api_key(raw)
    assert key_writes(fn -> {:ok, _, _} = Accounts.validate_api_key(raw) end) == []

    # Another node (empty debounce) trusts the stamp the key row carries.
    Engram.Cache.clear_local(:api_key_used)
    Engram.Cache.clear_local(:api_key)
    assert key_writes(fn -> {:ok, _, _} = Accounts.validate_api_key(raw) end) == []
  end

  test "an hour-old stamp is renewed", %{raw: raw, key: key} do
    old = DateTime.add(DateTime.utc_now(), -2, :hour) |> DateTime.truncate(:second)

    Repo.with_tenant!(key.user_id, fn ->
      Repo.update_all(from(k in ApiKey, where: k.id == ^key.id), set: [last_used: old])
    end)

    Engram.Cache.clear_local(:api_key)
    {:ok, _, _} = Accounts.validate_api_key(raw)
    assert DateTime.compare(last_used(key), old) == :gt
  end
end
