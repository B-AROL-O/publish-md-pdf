#!/bin/bash
# ==========================================================
# Unit tests for the pure helpers in lib/common.sh.
# Run via tests/run-tests.sh.
# ==========================================================

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
# shellcheck source=tests/assert.sh
source "$TESTS_DIR/assert.sh"
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"

# --- is_url ------------------------------------------------------------

assert_succeeds "is_url accepts https" is_url "https://example.com/x"
assert_succeeds "is_url accepts http" is_url "http://example.com/x"
assert_fails "is_url rejects a bare path" is_url "docs/report.md"
assert_fails "is_url rejects ftp" is_url "ftp://example.com/x"

# --- confluence_safe_basename ------------------------------------------
#
# This is the guard between a server-controlled attachment title and a path
# this tool writes to disk, so the traversal cases below are the point of the
# function rather than edge cases.

assert_eq "diagram.png" "$(confluence_safe_basename "diagram.png" "FB")" \
	"safe_basename leaves an already-safe name alone"
assert_eq "evil.png" "$(confluence_safe_basename "../../evil.png" "FB")" \
	"safe_basename strips a directory-traversal prefix"
assert_eq "passwd" "$(confluence_safe_basename "/etc/passwd" "FB")" \
	"safe_basename strips an absolute path"
assert_eq "c.png" "$(confluence_safe_basename "a/b/c.png" "FB")" \
	"safe_basename keeps only the basename"
assert_eq "My-Photo.JPG" "$(confluence_safe_basename "My Photo.JPG" "FB")" \
	"safe_basename folds spaces to a hyphen and keeps case/extension"
assert_eq "FB" "$(confluence_safe_basename ".." "FB")" \
	"safe_basename falls back for bare dots"
assert_eq "FB" "$(confluence_safe_basename "" "FB")" \
	"safe_basename falls back for an empty title"
LONG_NAME="$(confluence_safe_basename "$(printf 'a%.0s' {1..200})" "FB")"
assert_eq 100 "${#LONG_NAME}" \
	"safe_basename caps an over-long title at 100 characters"

# --- html_escape_attr / xml_unescape_attr ------------------------------

assert_eq "a?x=1&amp;y=2" "$(html_escape_attr 'a?x=1&y=2')" \
	"html_escape_attr escapes a bare ampersand"
assert_eq "&lt;b&gt; &quot;q&quot;" "$(html_escape_attr '<b> "q"')" \
	"html_escape_attr escapes angle brackets and quotes"
assert_eq 'a?x=1&y=2' "$(xml_unescape_attr 'a?x=1&amp;y=2')" \
	"xml_unescape_attr decodes an escaped ampersand"
assert_eq '&lt;' "$(xml_unescape_attr '&amp;lt;')" \
	"xml_unescape_attr undoes &amp; last, so &amp;lt; does not become a real <"

# A storage-format attribute arrives already escaped; decoding it and
# re-encoding it must land back where it started. Getting this wrong produced
# "&amp;amp;" in generated hrefs once already.
assert_eq "a?x=1&amp;y=2" "$(html_escape_attr "$(xml_unescape_attr 'a?x=1&amp;y=2')")" \
	"escape(unescape(x)) round-trips without doubling the escape"

# --- resolve_output_name ------------------------------------------------

assert_eq "report.pdf" "$(resolve_output_name "docs/report.md" md pdf "")" \
	"resolve_output_name derives the name from the input"
assert_eq "out.pdf" "$(resolve_output_name "docs/report.md" md pdf "out")" \
	"resolve_output_name appends the target extension to a requested name"
assert_eq "out.pdf" "$(resolve_output_name "docs/report.md" md pdf "out.pdf")" \
	"resolve_output_name does not double an extension already present"
assert_eq "page.md" "$(resolve_output_name "page.confluence" confluence md "")" \
	"resolve_output_name handles the confluence -> md direction"

assert_summary "common.sh"
