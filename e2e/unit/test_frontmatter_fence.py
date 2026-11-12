"""fm_block / fm_keys follow the shared fence rule (LF and CRLF)."""

from helpers.frontmatter_first_sync import fm_block, fm_keys


def test_lf_and_crlf_blocks():
    assert fm_block("---\na: 1\n---\nbody\n") == "a: 1\n"
    assert fm_block("---\r\na: 1\r\n---\r\nbody\r\n") == "a: 1\r\n"
    assert fm_block("---\r\na: 1\r\n---") == "a: 1\r\n"
    assert fm_block("---\n---\nbody") == ""


def test_not_frontmatter():
    assert fm_block("body\n---\na: 1\n---\n") is None
    assert fm_block("---\na: 1\n") is None
    assert fm_block("---\na: 1\n---foo\n") is None


def test_keys_keep_duplicates_and_skip_nested_lines():
    text = "---\r\ntitle: T\r\ntags:\r\n  - a\r\ntitle: T\r\n---\r\nx: not fm\r\n"
    assert fm_keys(text) == ["title", "tags", "title"]
    assert fm_keys("no frontmatter: here\n") == []
