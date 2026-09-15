defmodule Engram.OAuth.ClientTest do
  @moduledoc """
  The auth-method predicates, pinned against each other.

  No DB and no sandbox: every assertion here is on pure functions and on a
  changeset BEFORE it is inserted, so `apply_changes/1` is the whole story.
  """
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias Engram.OAuth.Client

  @url "https://vendor.example/.well-known/oauth-client"

  defp document(overrides) do
    Map.merge(
      %{
        "client_id" => @url,
        "client_name" => "Vendor",
        "redirect_uris" => ["https://vendor.example/cb"]
      },
      overrides
    )
  end

  # The row `cimd_changeset/3` would actually persist for this document.
  #
  # `apply_changes/1` ignores validity on purpose: the unknown-method case below
  # produces an INVALID changeset, and the question being asked is what the two
  # predicates answer for the same values — not whether the row would insert.
  defp row(document) do
    Changeset.apply_changes(Client.cimd_changeset(%Client{}, @url, document))
  end

  # `{label, document overrides, expected answer}`.
  #
  # The expected column is not redundant with the agreement assertion: agreement
  # alone would stay green if BOTH paths turned false, which is precisely the
  # regression #1633/#1639/#1640 were. One column pins truth, the other pins
  # that the two implementations cannot drift from each other.
  @documents [
    {"prefers private_key_jwt, no supported list",
     %{"token_endpoint_auth_method" => "private_key_jwt"}, true},

    # ChatGPT's real published shape, and the exact #1640 regression: the
    # preference is `none`, so reading it alone refused the assertion.
    {"prefers none, supports private_key_jwt",
     %{
       "token_endpoint_auth_method" => "none",
       "token_endpoint_auth_methods_supported" => ["none", "private_key_jwt"]
     }, true},

    # The mirror: the preferred method counts even when the supported list omits
    # it, because the effective set is the UNION of the two.
    {"prefers private_key_jwt, supports only none",
     %{
       "token_endpoint_auth_method" => "private_key_jwt",
       "token_endpoint_auth_methods_supported" => ["none"]
     }, true},
    {"prefers none, no supported list", %{"token_endpoint_auth_method" => "none"}, false},

    # An explicit `[]` and an absent key are both "named nothing extra", so
    # neither may widen the answer past the preferred method alone. They must
    # agree with each other on the ANSWER while still differing in what gets
    # stored (see the NULL-vs-[] describe below).
    {"prefers none, supported list present but empty",
     %{"token_endpoint_auth_method" => "none", "token_endpoint_auth_methods_supported" => []},
     false},
    {"prefers private_key_jwt, supported list present but empty",
     %{
       "token_endpoint_auth_method" => "private_key_jwt",
       "token_endpoint_auth_methods_supported" => []
     }, true},

    # Garbage in the preferred slot must not read as an assertion method. The row
    # this produces is invalid (the changeset refuses the value), but the
    # predicate still has to answer, and it has to answer the same way.
    {"unknown preferred method", %{"token_endpoint_auth_method" => "sorcery_jwt"}, false},

    # A method we refuse on the CIMD path is dropped on the way to the row, so
    # the document path has to drop it too or the two disagree.
    {"supported list names only methods we refuse",
     %{
       "token_endpoint_auth_method" => "none",
       "token_endpoint_auth_methods_supported" => ["client_secret_basic"]
     }, false},
    {"neither field", %{}, false}
  ]

  describe "document_permits_assertion?/1 vs assertion_permitted?/1" do
    # The invariant `document_permits_assertion?/1`'s own docstring claims and
    # that nothing enforced until this test: the document path and the row path
    # must answer identically for the same document, or a document passes
    # `validate_document/2` and then cannot authenticate (#1640).
    test "the two paths answer identically for every document shape" do
      for {label, overrides, expected} <- @documents do
        document = document(overrides)
        from_document = Client.document_permits_assertion?(document)
        from_row = Client.assertion_permitted?(row(document))

        assert from_document == from_row,
               "#{label}: document path says #{from_document}, row path says #{from_row}"

        assert from_document == expected,
               "#{label}: expected #{expected}, both paths said #{from_document}"
      end
    end

    # The premise the shared implementation rests on: every method the CIMD path
    # will store is one both predicates read the same way. Behavioural rather
    # than a restatement of the two module attributes, so it stays honest if
    # either list moves.
    test "the two paths agree for every auth method CIMD permits" do
      for method <- Client.cimd_auth_methods(),
          supported <- [nil, [], ["none"], ["private_key_jwt"], [method]] do
        overrides =
          case supported do
            nil ->
              %{"token_endpoint_auth_method" => method}

            list ->
              %{
                "token_endpoint_auth_method" => method,
                "token_endpoint_auth_methods_supported" => list
              }
          end

        document = document(overrides)

        assert Client.document_permits_assertion?(document) ==
                 Client.assertion_permitted?(row(document)),
               "disagreed for preferred #{method} with supported #{inspect(supported)}"
      end
    end

    test "a non-map document permits nothing" do
      for not_a_document <- [nil, "private_key_jwt", [], 42] do
        refute Client.document_permits_assertion?(not_a_document)
      end
    end
  end

  describe "NULL vs [] on token_endpoint_auth_methods_supported" do
    # A document ALWAYS yields `[]`, never NULL. `[]` means "the document was
    # read and named nothing we support"; NULL means "never read off a document"
    # (a row predating the column). Writing NULL from a document would forge
    # that provenance, and the refactor must not let one become the other.
    test "a document with no supported list stores [], not NULL" do
      stored = row(document(%{"token_endpoint_auth_method" => "private_key_jwt"}))

      assert stored.token_endpoint_auth_methods_supported == []
    end

    test "a document with an explicitly empty supported list also stores []" do
      stored =
        row(
          document(%{
            "token_endpoint_auth_method" => "private_key_jwt",
            "token_endpoint_auth_methods_supported" => []
          })
        )

      assert stored.token_endpoint_auth_methods_supported == []
    end

    # The legacy shape, unreachable from any document. NULL must not widen and
    # must not crash: only the preferred method counts for such a row.
    test "a NULL row falls back to its preferred method alone" do
      assert Client.permitted_auth_methods(%Client{
               token_endpoint_auth_method: "none",
               token_endpoint_auth_methods_supported: nil
             }) == ["none"]

      assert Client.assertion_permitted?(%Client{
               token_endpoint_auth_method: "private_key_jwt",
               token_endpoint_auth_methods_supported: nil
             })

      refute Client.assertion_permitted?(%Client{
               token_endpoint_auth_method: "none",
               token_endpoint_auth_methods_supported: nil
             })
    end

    test "a NULL row and an empty-list row answer identically" do
      for method <- ~w(none private_key_jwt) do
        null_row = %Client{
          token_endpoint_auth_method: method,
          token_endpoint_auth_methods_supported: nil
        }

        empty_row = %Client{
          token_endpoint_auth_method: method,
          token_endpoint_auth_methods_supported: []
        }

        assert Client.assertion_permitted?(null_row) ==
                 Client.assertion_permitted?(empty_row),
               "NULL and [] disagreed for preferred #{method}"

        assert Client.public_auth_permitted?(null_row) ==
                 Client.public_auth_permitted?(empty_row)
      end
    end
  end
end
