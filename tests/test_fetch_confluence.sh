#!/bin/bash
# ==========================================================
# Unit tests for the pure URL/name helpers in lib/fetch-confluence.sh.
#
# Only the functions that do no I/O are covered here; the ones that actually
# talk to the REST API are exercised by the "Confluence URL import" steps in
# .github/workflows/ci.yml against the nginx mock. Run via tests/run-tests.sh.
# ==========================================================

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
# shellcheck source=tests/assert.sh
source "$TESTS_DIR/assert.sh"
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/fetch-confluence.sh
source "$REPO_DIR/lib/fetch-confluence.sh"

BASE="https://example.atlassian.net/wiki"

# --- confluence_url_base / _origin / _page_id ---------------------------

assert_eq "$BASE" "$(confluence_url_base "$BASE/spaces/DEV/pages/12345/Title")" \
	"url_base extracts the /wiki base from a page URL"
assert_eq "$BASE" "$(confluence_url_base "$BASE")" \
	"url_base accepts the bare base itself"
assert_fails "url_base rejects a URL with no /wiki segment" \
	confluence_url_base "https://example.atlassian.net/nope"

assert_eq "https://example.atlassian.net" "$(confluence_url_origin "$BASE")" \
	"url_origin drops the /wiki suffix"

assert_eq "12345" "$(confluence_url_page_id "$BASE/spaces/DEV/pages/12345/Title")" \
	"page_id reads the current-UI /pages/<id> form"
assert_eq "999" "$(confluence_url_page_id "$BASE/foo?pageId=999")" \
	"page_id reads the legacy ?pageId=<id> form"
assert_fails "page_id fails when the URL carries no id" \
	confluence_url_page_id "https://example.atlassian.net/wiki/x/AbCdEf"

# --- confluence_attachment_url ------------------------------------------
#
# Security-critical. Every attachment is fetched with the same -K config that
# carries the Confluence API token, so a downloadLink naming another host must
# be refused rather than followed -- see the comment on the function, and
# .claude/memory/feedback_curl_url_effective_leaks_credentials.md for the
# incident that motivates it.

assert_eq "$BASE/rest/api/content/1/child/attachment/att1/download" \
	"$(confluence_attachment_url "$BASE" "/rest/api/content/1/child/attachment/att1/download")" \
	"attachment_url resolves a relative v1 link against the /wiki base, not the bare origin"
assert_eq "$BASE/download/attachments/1/x.png" \
	"$(confluence_attachment_url "$BASE" "$BASE/download/attachments/1/x.png")" \
	"attachment_url passes through an absolute same-origin link"
assert_fails "attachment_url refuses a cross-origin absolute link" \
	confluence_attachment_url "$BASE" "https://attacker.example.com/steal.png"
assert_fails "attachment_url refuses a protocol-relative link" \
	confluence_attachment_url "$BASE" "//attacker.example.com/steal.png"
assert_fails "attachment_url refuses a link that is not a URL or absolute path" \
	confluence_attachment_url "$BASE" "steal.png"

# --- confluence_attachment_dedupe ---------------------------------------
#
# The separator here is load-bearing: shfmt cannot tell this array is
# associative and once tried to respace "${stem}-${n}${ext}" as arithmetic,
# which would have written files named "diagram - 1.png".

declare -gA confluence_fetch_used_names=()

assert_eq "diagram.png" "$(confluence_attachment_dedupe "diagram.png")" \
	"dedupe leaves an unused name alone"
confluence_fetch_used_names["diagram.png"]=1
assert_eq "diagram-1.png" "$(confluence_attachment_dedupe "diagram.png")" \
	"dedupe suffixes before the extension, hyphen with no spaces"
confluence_fetch_used_names["diagram-1.png"]=1
assert_eq "diagram-2.png" "$(confluence_attachment_dedupe "diagram.png")" \
	"dedupe keeps counting past an already-taken suffix"
confluence_fetch_used_names["README"]=1
assert_eq "README-1" "$(confluence_attachment_dedupe "README")" \
	"dedupe handles an extensionless name"

# --- confluence_slug -----------------------------------------------------

assert_eq "hello-world-v2" "$(confluence_slug "Hello World! (v2)" 42)" \
	"slug lower-cases and folds punctuation to single hyphens"
assert_eq "confluence-42" "$(confluence_slug "!!!" 42)" \
	"slug falls back to confluence-<id> for an all-punctuation title"

# --- confluence_require_secure_url ---------------------------------------
#
# tests/run-tests.sh unsets PUBLISH_MD_PDF_ALLOW_INSECURE, so the default-deny
# case below tests the default rather than whatever the caller's shell had set.

assert_succeeds "require_secure_url accepts https" \
	confluence_require_secure_url "https://example.atlassian.net/wiki"
assert_fails "require_secure_url refuses plain http by default" \
	confluence_require_secure_url "http://example.atlassian.net/wiki"
PUBLISH_MD_PDF_ALLOW_INSECURE=1 \
	assert_succeeds "require_secure_url allows http under the override" \
	confluence_require_secure_url "http://127.0.0.1:18085/wiki"

assert_summary "fetch-confluence.sh"
