defmodule Engram.Links.LinkKeysIndexTest do
  # The `*_link_keys_stale_index`es inline the Unicode version `Engram.Links`
  # stamps keys with. After an Elixir upgrade moves it, reads stay correct
  # but stop using these indexes, so this fails until a migration rebuilds
  # them with the new literal.
  use Engram.DataCase, async: true

  alias Engram.Links

  test "the stale-key partial indexes match the current link keys version" do
    literal = "\\x" <> Base.encode16(Links.link_keys_version(), case: :lower)

    %{rows: rows} =
      Repo.query!("""
      SELECT indexname, indexdef FROM pg_indexes
      WHERE indexname IN ('notes_link_keys_stale_index',
                          'attachments_link_keys_stale_index',
                          'note_links_link_keys_stale_index')
      """)

    assert length(rows) == 3

    for [name, def] <- rows do
      assert def =~ literal, "#{name} predicate lacks #{literal}: #{def}"
    end
  end
end
