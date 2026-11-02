#!/bin/bash
# ==========================================================
# Unit tests for the pure helpers in lib/fetch-github.sh and the Markdown
# renderer in lib/github-md.jq.
#
# Only the functions that do no I/O are covered here; the ones that actually
# talk to the REST API are exercised by the "GitHub URL import" steps in
# .github/workflows/ci.yml against an nginx mock. Needs jq, but neither the
# network nor pandoc. Run via tests/run-tests.sh.
# ==========================================================

# Most expected values below are Markdown, full of literal backticks and "$"
# that are meant to stay unexpanded -- which is what SC2016 flags. Placed
# before the first command, so it covers the whole file.
# shellcheck disable=SC2016

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
# shellcheck source=tests/assert.sh
source "$TESTS_DIR/assert.sh"
# shellcheck source=lib/common.sh
source "$REPO_DIR/lib/common.sh"
# shellcheck source=lib/fetch-github.sh
source "$REPO_DIR/lib/fetch-github.sh"

# The API-base tests below assert the built-in host table, which a runner's
# own GITHUB_SERVER_URL/GITHUB_API_URL would otherwise override.
unset GITHUB_SERVER_URL GITHUB_API_URL

# jq with lib/github-md.jq included, reading its input from stdin.
gh_jq() {
	jq -r -L "$REPO_DIR/lib" "include \"github-md\"; $1"
}

# --- is_github_url / github_url_parts -----------------------------------

assert_succeeds "is_github_url accepts an issue URL" \
	is_github_url "https://github.com/B-AROL-O/publish-md-pdf/issues/42"
assert_succeeds "is_github_url accepts a pull request URL with a trailing /files" \
	is_github_url "https://github.com/B-AROL-O/publish-md-pdf/pull/16/files"
assert_succeeds "is_github_url accepts a URL with a comment anchor" \
	is_github_url "https://github.com/o/r/issues/1#issuecomment-123"
assert_succeeds "is_github_url accepts a GHE.com URL" \
	is_github_url "https://acme.ghe.com/org/repo/issues/7"
assert_fails "is_github_url rejects a repository URL with no issue number" \
	is_github_url "https://github.com/B-AROL-O/publish-md-pdf"
assert_fails "is_github_url rejects the /pulls list" \
	is_github_url "https://github.com/o/r/pulls/1"
assert_fails "is_github_url rejects a number followed by more digits-and-letters" \
	is_github_url "https://github.com/o/r/issues/12abc"
assert_fails "is_github_url leaves a Confluence page URL to the Confluence importer" \
	is_github_url "https://example.atlassian.net/wiki/spaces/DEV/pages/12345/Title"

assert_eq "https://github.com B-AROL-O publish-md-pdf 16" \
	"$(github_url_parts "https://GitHub.com/B-AROL-O/publish-md-pdf/pull/16/files")" \
	"url_parts lower-cases the host but not the owner/repo, and drops the /files suffix"

# --- github_api_base ------------------------------------------------------
#
# Security-critical: the token is sent wherever this points, so a host that
# merely resembles a supported one must not map to anything.

assert_eq "https://api.github.com" "$(github_api_base "https://github.com")" \
	"api_base maps github.com to api.github.com"
assert_eq "https://api.acme.ghe.com" "$(github_api_base "https://acme.ghe.com")" \
	"api_base maps a GHE.com tenant to its api. host"
assert_fails "api_base refuses a nested *.ghe.com host" \
	github_api_base "https://a.b.ghe.com"
assert_fails "api_base refuses a host that only starts with github.com" \
	github_api_base "https://github.com.attacker.example"
assert_fails "api_base refuses plain-HTTP github.com" \
	github_api_base "http://github.com"
assert_fails "api_base refuses an unknown host (e.g. GitHub Enterprise Server)" \
	github_api_base "https://github.example.com"
assert_eq "https://github.example.com/api/v3" \
	"$(GITHUB_SERVER_URL=https://GitHub.example.com/ GITHUB_API_URL=https://github.example.com/api/v3/ \
		github_api_base "https://github.example.com")" \
	"api_base uses GITHUB_API_URL for the host GITHUB_SERVER_URL names"
assert_eq "https://api.github.com" \
	"$(GITHUB_SERVER_URL=https://github.example.com GITHUB_API_URL=https://github.example.com/api/v3 \
		github_api_base "https://github.com")" \
	"api_base keeps the built-in mapping for any other host"

# --- github_require_secure_url ----------------------------------------------

assert_succeeds "require_secure_url accepts https" \
	github_require_secure_url "https://api.github.com/repos/o/r"
assert_fails "require_secure_url refuses plain http by default" \
	github_require_secure_url "http://127.0.0.1:18086/api/v3/repos/o/r"
PUBLISH_MD_PDF_ALLOW_INSECURE=1 \
	assert_succeeds "require_secure_url allows http under the override" \
	github_require_secure_url "http://127.0.0.1:18086/api/v3/repos/o/r"

# --- github_attachment_uuid -------------------------------------------------
#
# Only an image GitHub stores, on the issue's own server, is ever fetched
# with the token.

UUID="b35d8f92-e72d-4e36-b0a0-13c2dde62784"
assert_eq "$UUID" \
	"$(github_attachment_uuid "https://github.com/user-attachments/assets/$UUID" "https://github.com")" \
	"attachment_uuid reads a /user-attachments/assets/ URL"
assert_eq "$UUID" \
	"$(github_attachment_uuid "https://github.com/o/r/assets/75182/$UUID" "https://github.com")" \
	"attachment_uuid reads the older /OWNER/REPO/assets/<id>/ URL"
assert_fails "attachment_uuid refuses the same path on another host" \
	github_attachment_uuid "https://attacker.example/user-attachments/assets/$UUID" "https://github.com"
assert_fails "attachment_uuid refuses a host that only starts with the origin" \
	github_attachment_uuid "https://github.com.attacker.example/user-attachments/assets/$UUID" "https://github.com"
assert_fails "attachment_uuid refuses a /user-attachments/files/ download" \
	github_attachment_uuid "https://github.com/user-attachments/files/123/report.zip" "https://github.com"

# --- github_markdown_image_urls ---------------------------------------------

md_file="$(mktemp)"
register_cleanup "$md_file"
cat >"$md_file" <<EOF
![screenshot](https://github.com/user-attachments/assets/$UUID)
<img width="728" alt="Image" src="https://github.com/user-attachments/assets/$UUID" />
[a link, not an image](https://github.com/user-attachments/assets/00000000-0000-0000-0000-000000000000)
EOF
assert_eq "https://github.com/user-attachments/assets/$UUID" "$(github_markdown_image_urls "$md_file")" \
	"markdown_image_urls finds ![]() and <img src>, once each, and skips a plain link"

# --- lib/github-md.jq: helpers ----------------------------------------------

assert_eq '```' "$(jq -n '"plain"' | gh_jq 'fence(.)')" \
	"fence is three backticks for text without any"
assert_eq '````' "$(jq -n '"a ```js fenced``` block"' | gh_jq 'fence(.)')" \
	"fence outruns a diff hunk that itself contains a code fence"

assert_eq 'a \| b c' "$(jq -n '"a | b\nc"' | gh_jq 'cell')" \
	"cell escapes a pipe and folds a newline, either of which would break the table row"

assert_eq "2026-10-29 06:32 UTC" "$(jq -n '"2026-10-29T06:32:08Z"' | gh_jq 'ts')" \
	"ts formats an API timestamp"

# The bug this guards against: a PR description's own "## What" landing beside
# the document's "## Description" instead of under it.
assert_eq $'### What\ntext\n#### Detail' \
	"$(jq -n '"## What\ntext\n### Detail"' | gh_jq 'nest_headings(2)')" \
	"nest_headings shifts a body's headings just below its parent heading"
assert_eq $'### Summary' "$(jq -n '"### Summary"' | gh_jq 'nest_headings(2)')" \
	"nest_headings leaves a body that already nests (an issue template's h3) alone"
assert_eq $'#### Top\n```sh\n# a shell comment\n```\n##### Sub' \
	"$(jq -n '"# Top\n```sh\n# a shell comment\n```\n## Sub"' | gh_jq 'nest_headings(3)')" \
	"nest_headings leaves a # line inside a fenced code block alone"
assert_eq $'#notaheading' "$(jq -n '"#notaheading"' | gh_jq 'nest_headings(3)')" \
	"nest_headings ignores a # with no space after it"
assert_eq "######" "$(jq -n '"#####"' | gh_jq 'nest_headings(5) | split(" ")[0]')" \
	"nest_headings caps at h6"
assert_eq $'line one\nline two' "$(jq -n '"line one\r\nline two"' | gh_jq 'body_at(2; "x")')" \
	"body_at normalizes CRLF from the web editor"
assert_eq "_No comment._" "$(jq -n '"  \r\n"' | gh_jq 'body_at(3; "_No comment._")')" \
	"body_at falls back to the placeholder for a blank body"

# --- lib/github-md.jq: a whole pull request ---------------------------------

# A synthetic PR with one of everything: a title that needs YAML escaping, a
# label with a pipe in it, a comment and a review that must interleave by date,
# an inline thread with a reply, a reply-only review that must not show up as
# an empty entry of its own, and a pending review that must not show at all.
pr_json='{
  "issue": {
    "number": 7, "title": "Fix \"quotes\": and colons", "state": "closed",
    "html_url": "https://github.com/o/r/pull/7",
    "user": {"login": "alice"}, "created_at": "2026-01-01T10:00:00Z",
    "updated_at": "2026-01-03T10:00:00Z", "closed_at": "2026-01-03T09:00:00Z",
    "labels": [{"name": "a|b"}], "assignees": [], "milestone": null,
    "body": "## What\r\nThe change.", "pull_request": {}
  },
  "pull": {
    "merged": true, "merged_at": "2026-01-03T09:00:00Z", "merged_by": {"login": "bob"},
    "draft": false, "head": {"label": "o:feature"}, "base": {"label": "o:main"},
    "commits": 1, "changed_files": 1, "additions": 3, "deletions": 1,
    "requested_reviewers": []
  },
  "comments": [
    {"user": {"login": "carol"}, "created_at": "2026-01-02T12:00:00Z", "body": "Second."}
  ],
  "reviews": [
    {"id": 1, "user": {"login": "bob"}, "state": "CHANGES_REQUESTED",
     "submitted_at": "2026-01-02T11:00:00Z", "body": "First."},
    {"id": 2, "user": {"login": "alice"}, "state": "COMMENTED",
     "submitted_at": "2026-01-02T13:00:00Z", "body": ""},
    {"id": 3, "user": {"login": "dave"}, "state": "PENDING",
     "submitted_at": null, "body": "Draft review."}
  ],
  "review_comments": [
    {"id": 10, "pull_request_review_id": 1, "in_reply_to_id": null,
     "path": "README.md", "line": 4, "original_line": 4,
     "diff_hunk": "@@ -1,3 +1,4 @@\n ```sh\n+echo hi\n ```",
     "user": {"login": "bob"}, "created_at": "2026-01-02T11:00:00Z", "body": "Why?"},
    {"id": 11, "pull_request_review_id": 2, "in_reply_to_id": 10,
     "path": "README.md", "line": 4, "original_line": 4, "diff_hunk": "",
     "user": {"login": "alice"}, "created_at": "2026-01-02T13:00:00Z", "body": "Because."}
  ],
  "commits": [
    {"sha": "0123456789abcdef", "author": {"login": "alice"},
     "commit": {"message": "Fix it\n\nLong body", "author": {"name": "Alice", "date": "2026-01-01T09:00:00Z"}}}
  ],
  "files": [
    {"filename": "README.md", "previous_filename": null, "status": "modified", "additions": 3, "deletions": 1}
  ]
}'
pr_md="$(printf '%s' "$pr_json" | gh_jq '
	github_md("https://github.com/o/r/pull/7"; .issue; .pull; .comments; .reviews;
		.review_comments; .commits; .files)')"

assert_eq 'title: "Fix \"quotes\": and colons #7"' "$(grep '^title:' <<<"$pr_md")" \
	"github_md writes a YAML-safe title"
assert_eq 'github_kind: "pull_request"' "$(grep '^github_kind:' <<<"$pr_md")" \
	"github_md records the kind in front matter"
assert_eq '| **State** | Merged |' "$(grep -F '**State**' <<<"$pr_md")" \
	"github_md reports a merged PR as Merged, not Closed"
assert_eq '| **Labels** | a\|b |' "$(grep -F '**Labels**' <<<"$pr_md")" \
	"github_md escapes a pipe in a label name"
assert_eq "### What" "$(grep -x '### What' <<<"$pr_md")" \
	"github_md nests the description's headings under ## Description"
assert_eq $'### @bob requested changes on 2026-01-02 11:00 UTC\n### @carol commented on 2026-01-02 12:00 UTC' \
	"$(grep '^### @' <<<"$pr_md")" \
	"github_md interleaves reviews and comments by date, skipping reply-only and pending reviews"
assert_eq '#### `README.md` (line 4)' "$(grep '^#### ' <<<"$pr_md")" \
	"github_md heads an inline thread with its file and line"
assert_eq '````diff' "$(grep '^````diff' <<<"$pr_md")" \
	"github_md fences a diff hunk containing a code fence with a longer fence"
assert_eq '**@alice** on 2026-01-02 13:00 UTC:' "$(grep -F '**@alice**' <<<"$pr_md")" \
	"github_md shows a reply under the thread it answers"
assert_succeeds "github_md leaves out a pending review" \
	bash -c '! grep -q "Draft review" <<<"$1"' _ "$pr_md"
assert_eq '| `0123456` | Fix it | @alice | 2026-01-01 09:00 UTC |' "$(grep -F '`0123456`' <<<"$pr_md")" \
	"github_md lists a commit by short SHA and subject line only"
assert_eq '| `README.md` | modified | +3 | −1 |' "$(grep -F '| `README.md` |' <<<"$pr_md")" \
	"github_md lists a changed file with its line counts"

# --- lib/github-md.jq: a plain issue ----------------------------------------

issue_md="$(jq -n '{number: 3, title: "Bug", state: "closed", state_reason: "not_planned",
	html_url: "https://acme.ghe.com/org/repo/issues/3", user: null,
	created_at: "2026-01-01T10:00:00Z", updated_at: "2026-01-01T10:00:00Z",
	closed_at: "2026-01-01T11:00:00Z", closed_by: {login: "eve"},
	labels: [], assignees: [], milestone: {title: "v1"}, body: null}' | gh_jq '
	github_md("https://acme.ghe.com/org/repo/issues/3"; .; null; []; []; []; []; [])')"

assert_eq '| **State** | Closed (not planned) |' "$(grep -F '**State**' <<<"$issue_md")" \
	"github_md reports an issue's close reason"
assert_eq '| **Closed** | 2026-01-01 11:00 UTC by @eve |' "$(grep -F '**Closed**' <<<"$issue_md")" \
	"github_md says who closed an issue"
assert_eq '| **Repository** | [org/repo](https://acme.ghe.com/org/repo) |' "$(grep -F '**Repository**' <<<"$issue_md")" \
	"github_md links the repository on its own (GHE.com) host"
assert_eq "_No description provided._" "$(grep -F 'No description' <<<"$issue_md")" \
	"github_md fills in an empty description"
assert_eq "@ghost" "$(grep -o '@ghost' <<<"$issue_md" | head -1)" \
	"github_md shows a deleted account as @ghost, as GitHub does"
assert_succeeds "github_md has no PR-only sections for an issue" \
	bash -c '! grep -qE "^## (Conversation|Commits|Changed files)" <<<"$1"' _ "$issue_md"

assert_summary "fetch-github.sh"
