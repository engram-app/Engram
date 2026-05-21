defmodule Mix.Tasks.Engram.Lint.LimitKeysTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Engram.Lint.LimitKeys, as: Lint

  defp scan(source) do
    Lint.scan_source!(source, "test.ex")
  end

  describe "valid call sites" do
    test "fully qualified Engram.Billing.effective_limit with catalog atom passes" do
      src = """
      defmodule X do
        def f(user), do: Engram.Billing.effective_limit(user, :notes_cap)
      end
      """

      assert scan(src) == []
    end

    test "aliased Billing.check_limit with catalog atom passes" do
      src = """
      defmodule X do
        alias Engram.Billing
        def f(user), do: Billing.check_limit(user, :vaults_cap, 5)
      end
      """

      assert scan(src) == []
    end

    test "aliased Billing.check_feature with catalog atom passes" do
      src = """
      defmodule X do
        alias Engram.Billing
        def f(user), do: Billing.check_feature(user, :reranker_enabled)
      end
      """

      assert scan(src) == []
    end

    test "non-billing call (Billing.tier) is ignored" do
      src = """
      defmodule X do
        alias Engram.Billing
        def f(user), do: Billing.tier(user)
      end
      """

      assert scan(src) == []
    end
  end

  describe "violations" do
    test "unknown atom flagged as :unknown_atom" do
      src = """
      defmodule X do
        def f(user), do: Engram.Billing.effective_limit(user, :bogus_key)
      end
      """

      assert [{_, _, :effective_limit, :unknown_atom, :bogus_key}] = scan(src)
    end

    test "string key flagged as :string_key" do
      src = """
      defmodule X do
        def f(user), do: Engram.Billing.effective_limit(user, "notes_cap")
      end
      """

      assert [{_, _, :effective_limit, :string_key, "notes_cap"}] = scan(src)
    end

    test "dynamic variable key flagged as :dynamic_key" do
      src = """
      defmodule X do
        def f(user, key), do: Engram.Billing.effective_limit(user, key)
      end
      """

      assert [{_, _, :effective_limit, :dynamic_key, _}] = scan(src)
    end

    test "dynamic key with `# lint:limit_keys allow_dynamic` annotation passes" do
      src = """
      defmodule X do
        def f(user, key) do
          # lint:limit_keys allow_dynamic
          Engram.Billing.effective_limit(user, key)
        end
      end
      """

      assert scan(src) == []
    end
  end

  describe "self-scan against engram codebase" do
    test "lint passes against current lib/ and test/" do
      violations =
        (Path.wildcard("lib/**/*.ex") ++ Path.wildcard("test/**/*.exs"))
        |> Enum.flat_map(fn file ->
          Lint.scan_source!(File.read!(file), file)
        end)

      assert violations == [],
             "Found #{length(violations)} limit-key violations:\n" <>
               Enum.map_join(violations, "\n", &inspect/1)
    end
  end
end
