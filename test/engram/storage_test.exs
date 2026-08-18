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
      uid = "u"
      vid = "v"
      refute Storage.object_key(uid, vid, "a") == Storage.object_key(uid, vid, "b")
    end
  end

  # A storage key ends up in the S3 URL, and from there in ExAws's own log
  # line, S3 access logs, CDN logs and bucket listings — none of which any
  # call-site control in this codebase can reach. So the key itself must not be
  # able to carry a vault path.
  #
  # `Storage.key/3` built "user/vault/<cleartext path>" and was deleted. The
  # read path in `attachments.ex` used to rebuild it whenever `storage_key` was
  # nil, which meant a path key could be minted at READ time on a row that had
  # never had one.
  describe "keys cannot carry a vault path" do
    test "no path-derived key builder is exported" do
      refute function_exported?(Storage, :key, 3),
             "Storage.key/3 built a path-derived key and was deleted — do not reintroduce it"
    end

    # The property that matters, stated over the builder that remains: whatever
    # the note is called, the key is the same shape and holds no folder name.
    test "the key is unchanged by the attachment's path or title" do
      uid = Ecto.UUID.generate()
      vid = Ecto.UUID.generate()
      att = Ecto.UUID.generate()

      key = Storage.object_key(uid, vid, att)

      assert key == "#{uid}/#{vid}/objects/#{att}"
      refute key =~ "Medical"
      refute key =~ ".md"
      # Exactly three separators: user, vault, "objects", id. A path would add
      # one per folder.
      assert key |> String.graphemes() |> Enum.count(&(&1 == "/")) == 3
    end
  end
end
