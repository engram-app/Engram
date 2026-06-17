defmodule Engram.StorageTest do
  use ExUnit.Case, async: true
  alias Engram.Storage

  describe "object_key/3" do
    test "keys by uuid under an objects/ namespace, independent of vault path" do
      uid = "11111111-1111-1111-1111-111111111111"
      vid = "22222222-2222-2222-2222-222222222222"
      att = "33333333-3333-3333-3333-333333333333"
      assert Storage.object_key(uid, vid, att) == "#{uid}/#{vid}/objects/#{att}"
    end

    test "two different uuids never collide even for the same future path" do
      uid = "u"; vid = "v"
      refute Storage.object_key(uid, vid, "a") == Storage.object_key(uid, vid, "b")
    end
  end
end
