defmodule Engram.Auth.EmailNormalizerTest do
  use ExUnit.Case, async: true

  alias Engram.Auth.EmailNormalizer

  describe "normalize/1 — gmail" do
    test "strips dots from local part" do
      assert EmailNormalizer.normalize("a.b@gmail.com") == "ab@gmail.com"
    end

    test "strips plus-suffix" do
      assert EmailNormalizer.normalize("me+foo@gmail.com") == "me@gmail.com"
    end

    test "strips dots AND plus-suffix" do
      assert EmailNormalizer.normalize("me.foo+bar@gmail.com") == "mefoo@gmail.com"
    end

    test "canonicalizes googlemail.com to gmail.com (same mailbox)" do
      assert EmailNormalizer.normalize("a.b+x@googlemail.com") == "ab@gmail.com"
    end

    test "same_identity? holds across gmail.com and googlemail.com" do
      assert EmailNormalizer.same_identity?("me@gmail.com", "me@googlemail.com")
    end

    test "empty plus-suffix collapses" do
      assert EmailNormalizer.normalize("me+@gmail.com") == "me@gmail.com"
    end

    test "everything after first plus is dropped" do
      assert EmailNormalizer.normalize("me+a+b@gmail.com") == "me@gmail.com"
    end

    test "lowercases the address" do
      assert EmailNormalizer.normalize("ME.FOO+BAR@GMAIL.COM") == "mefoo@gmail.com"
    end
  end

  describe "normalize/1 — fastmail" do
    test "strips plus-suffix" do
      assert EmailNormalizer.normalize("me+x@fastmail.com") == "me@fastmail.com"
    end

    test "preserves dots (fastmail does NOT collapse them)" do
      assert EmailNormalizer.normalize("me.foo+x@fastmail.com") == "me.foo@fastmail.com"
    end

    test "fastmail.fm domain also normalizes plus-suffix" do
      assert EmailNormalizer.normalize("me+x@fastmail.fm") == "me@fastmail.fm"
    end
  end

  describe "normalize/1 — proton" do
    test "strips plus-suffix on proton.me" do
      assert EmailNormalizer.normalize("me+x@proton.me") == "me@proton.me"
    end

    test "strips plus-suffix on protonmail.com" do
      assert EmailNormalizer.normalize("me+x@protonmail.com") == "me@protonmail.com"
    end

    test "preserves dots on proton" do
      assert EmailNormalizer.normalize("me.foo+x@proton.me") == "me.foo@proton.me"
    end
  end

  describe "normalize/1 — icloud" do
    test "strips plus-suffix on icloud.com" do
      assert EmailNormalizer.normalize("me+x@icloud.com") == "me@icloud.com"
    end

    test "preserves dots on icloud" do
      assert EmailNormalizer.normalize("me.foo+x@icloud.com") == "me.foo@icloud.com"
    end
  end

  describe "normalize/1 — business domains (no normalization)" do
    test "preserves dots and plus on unknown domain" do
      assert EmailNormalizer.normalize("user.name+x@acme.co") == "user.name+x@acme.co"
    end

    test "lowercases unknown domain emails" do
      assert EmailNormalizer.normalize("User.Name+X@ACME.CO") == "user.name+x@acme.co"
    end
  end

  describe "normalize/1 — input hygiene" do
    test "trims surrounding whitespace" do
      assert EmailNormalizer.normalize("  user@gmail.com  ") == "user@gmail.com"
    end

    test "malformed input (no @) is lowercased but otherwise unchanged" do
      assert EmailNormalizer.normalize("not-an-email") == "not-an-email"
    end

    test "empty string returns empty string" do
      assert EmailNormalizer.normalize("") == ""
    end
  end

  describe "same_identity?/2" do
    test "true for gmail dotted/plus variants of same address" do
      assert EmailNormalizer.same_identity?("a.b+x@gmail.com", "ab+y@gmail.com")
    end

    test "false for different local parts on gmail" do
      refute EmailNormalizer.same_identity?("a@gmail.com", "b@gmail.com")
    end

    test "true for unknown domain only when literal-equal after lowercase" do
      assert EmailNormalizer.same_identity?("USER@acme.co", "user@acme.co")
      refute EmailNormalizer.same_identity?("user+x@acme.co", "user@acme.co")
    end
  end
end
