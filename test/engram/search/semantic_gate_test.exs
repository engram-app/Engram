defmodule Engram.Search.SemanticGateTest do
  use Engram.DataCase, async: true

  import Engram.Factory

  alias Engram.Search
  alias Engram.Search.SearchProfile

  describe "effective_mode/2" do
    test "a keyword-only user gets :keyword no matter what was requested" do
      profile = %SearchProfile{semantic: false}

      # :vector is the default in do_search/4, :hybrid is what the REST
      # controller sends, and an MCP tool arg can supply any of them.
      for requested <- [:vector, :hybrid, :keyword] do
        assert Search.effective_mode(requested, profile) == :keyword
      end
    end

    test "an entitled user keeps the mode they asked for" do
      profile = %SearchProfile{semantic: true}

      for requested <- [:vector, :hybrid, :keyword] do
        assert Search.effective_mode(requested, profile) == requested
      end
    end
  end

  describe "SearchProfile.resolve/1" do
    test "free resolves semantic: false" do
      assert %SearchProfile{semantic: false} = SearchProfile.resolve(insert(:user))
    end
  end
end
