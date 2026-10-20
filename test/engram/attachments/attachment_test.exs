defmodule Engram.Attachments.AttachmentTest do
  use ExUnit.Case, async: true

  alias Engram.Attachments.Attachment

  @base %{
    user_id: Ecto.UUID.generate(),
    vault_id: Ecto.UUID.generate(),
    content_hash: "h",
    mime_type: "application/pdf",
    size_bytes: 10,
    path_ciphertext: "pc",
    path_nonce: "pn",
    path_hmac: "ph"
  }

  @v2 %{
    encryption_version: 2,
    wrapped_file_key: "wk",
    file_key_nonce: "kn",
    upload_id: Ecto.UUID.generate(),
    segment_size: 8_388_608,
    segment_count: 2
  }

  defp changeset(attrs), do: Attachment.changeset(%Attachment{}, Map.merge(@base, attrs))

  test "v1 still requires content_nonce" do
    assert changeset(%{content_nonce: "n"}).valid?
    refute changeset(%{}).valid?
    refute changeset(%{encryption_version: 1, wrapped_file_key: "wk"}).valid?
  end

  test "v2 is valid with the five segmented fields and no content_nonce" do
    assert changeset(@v2).valid?
  end

  test "v2 is invalid when any segmented field is missing" do
    for field <- [:wrapped_file_key, :file_key_nonce, :upload_id, :segment_size, :segment_count] do
      refute changeset(Map.delete(@v2, field)).valid?, "missing #{field}"
    end
  end

  test "v2 rejects content_nonce, and other versions are rejected" do
    refute changeset(Map.put(@v2, :content_nonce, "n")).valid?
    refute changeset(%{encryption_version: 3, content_nonce: "n"}).valid?
  end

  test "v2 segment counts are positive" do
    refute changeset(%{@v2 | segment_count: 0}).valid?
    refute changeset(%{@v2 | segment_size: 0}).valid?
  end
end
