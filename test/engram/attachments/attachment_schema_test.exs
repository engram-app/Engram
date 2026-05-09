defmodule Engram.Attachments.AttachmentSchemaTest do
  use Engram.DataCase, async: false

  alias Engram.Attachments.Attachment

  test "schema declares :dek_version_pending field as integer or nil" do
    fields = Attachment.__schema__(:fields)
    assert :dek_version_pending in fields
    assert Attachment.__schema__(:type, :dek_version_pending) == :integer
  end
end
