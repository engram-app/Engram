defmodule Engram.IndexingLanguageTest do
  # async: false — swaps the global :keyword_index adapter via Application env.
  use Engram.DataCase, async: false

  import Mox

  alias Engram.Crypto
  alias Engram.Indexing
  alias Engram.KeywordIndex.LangDetect
  alias Engram.Notes
  alias Engram.ServiceConfig

  defmodule RecordingKeywordIndex do
    @moduledoc false
    @behaviour Engram.KeywordIndex

    alias Engram.KeywordIndex.QdrantSparse

    @impl true
    def encode_document(text, filter_key, doc_len, avgdl, language) do
      send(self(), {:encode_document_language, language})
      QdrantSparse.encode_document(text, filter_key, doc_len, avgdl, language)
    end

    @impl true
    def encode_query(query, filter_key, language),
      do: QdrantSparse.encode_query(query, filter_key, language)
  end

  setup :verify_on_exit!

  setup do
    bypass = Bypass.open()
    ServiceConfig.put_override(:qdrant_url, "http://localhost:#{bypass.port}")

    Application.put_env(:engram, :keyword_index, RecordingKeywordIndex)
    on_exit(fn -> Application.delete_env(:engram, :keyword_index) end)

    {:ok, user} = Crypto.ensure_user_dek(insert(:user))
    vault = insert(:vault, user: user)

    %{bypass: bypass, user: user, vault: vault}
  end

  # A note whose sections are in different languages. Per-CHUNK detection tags
  # the German section :de and the English one :en; per-NOTE detection resolves
  # the note once and every chunk shares it.
  @mixed_content """
  # Introduction

  The quick brown fox jumps over the lazy dog while the sun rises slowly over
  the quiet English countryside on this particular morning.

  # Zusammenfassung

  Der Hund und die Katze sind zusammen im Garten und spielen dort den ganzen
  Tag ohne eine einzige Pause zu machen.
  """

  test "language is resolved once per note, not once per chunk", %{
    bypass: bypass,
    user: user,
    vault: vault
  } do
    {:ok, note} =
      Notes.upsert_note(user, vault, %{
        "path" => "mixed.md",
        "content" => @mixed_content,
        "mtime" => 1_000.0
      })

    {:ok, note} = Crypto.maybe_decrypt_note_fields(note, user)

    Engram.MockEmbedder
    |> expect(:embed_texts, fn texts ->
      {:ok, Enum.map(texts, fn _ -> [0.1, 0.2, 0.3] end)}
    end)

    Bypass.expect(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({"result": true}))
    end)

    {:ok, prepared} = Indexing.prepare_index(note, vault)

    languages = drain_languages()

    # Guard the fixture: if the note ever stops producing multiple chunks this
    # test proves nothing, so fail loudly rather than pass vacuously.
    assert length(languages) > 1,
           "fixture produced #{length(languages)} chunk(s); need >1 to test per-note detection"

    assert length(languages) == length(prepared.chunk_rows)

    assert [note_language] = Enum.uniq(languages),
           "expected one language for the whole note, got #{inspect(Enum.uniq(languages))}"

    # And it is the language of the NOTE, not of whichever chunk happened to be first.
    assert note_language == LangDetect.detect(@mixed_content)
  end

  defp drain_languages(acc \\ []) do
    receive do
      {:encode_document_language, language} -> drain_languages([language | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
