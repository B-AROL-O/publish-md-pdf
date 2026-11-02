# ==========================================================
# Renders a GitHub issue or pull request, as returned by the REST API, into
# one GitHub Flavored Markdown document for publish-md-pdf.sh's pdf/md/
# confluence conversions.
#
# A jq module (definitions only): lib/fetch-github.sh includes it and calls
# github_md, and tests/test_fetch_github.sh calls the helpers below directly.
# Everything here is pure -- no I/O beyond its arguments -- so the tests run
# against hand-written JSON with no network at all.
#
# Timeline events (labeled, assigned, referenced...) are deliberately left
# out: the header table summarizes the issue's *current* state, and the
# conversation below it is comments and reviews only, in date order.
# ==========================================================

# "2026-10-29T06:32:08Z" -> "2026-10-29 06:32 UTC"
def ts:
  if . == null then ""
  else sub("T"; " ") | sub(":[0-9]{2}Z$"; " UTC")
  end;

def who: "@" + (if . == null then "ghost" else .login end);

# A value headed for a table cell: a newline would end the row, and a bare
# "|" would start a new cell. Both are server-controlled text (a label name,
# a commit message), not something this tool chose.
def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|");

# A code fence long enough to enclose $s: one backtick longer than the
# longest run of backticks inside it, and never shorter than three. A diff
# hunk of a Markdown file routinely contains ``` itself, which would
# otherwise close the fence early and spill the rest of the hunk out as
# formatted text.
def fence($s):
  ([$s | scan("`+") | length] | max // 0) as $n
  | [range([3, $n + 1] | max)] | map("`") | join("");

def text_or($placeholder):
  if (. // "") | test("^\\s*$") then $placeholder else . end;

# Nests every ATX heading in a user-written body under a heading of level
# $parent: the whole body is shifted down just far enough that its shallowest
# heading becomes level $parent + 1 (capped at h6), so a description's own
# "## What" sits under this document's "## Description" rather than beside
# it, while an issue template's "### Summary" stays an h3. WeasyPrint turns
# every heading into a PDF bookmark, and an outline in which a comment's
# headings outrank the comment itself is unreadable.
#
# Lines inside a fenced code block are left alone -- a "#" comment in a shell
# snippet isn't a heading -- which is why this tracks fences line by line
# rather than running one regular expression over the whole body. Setext
# headings (text underlined with === or ---) are not shifted.
def nest_headings($parent):
  split("\n")
  | reduce .[] as $line ({lines: [], fence: null};
      if .fence == null then
        ($line | capture("^ {0,3}(?<f>`{3,}|~{3,})")? // null) as $open
        | if $open != null then .fence = $open.f | .lines += [{text: $line}]
          else .lines += [{text: $line, heading: ($line | capture("^(?<i> {0,3})(?<h>#{1,6})(?<rest>([ \t].*)?)$")? // null)}]
          end
      else
        (.fence) as $f
        | ($line | capture("^ {0,3}(?<f>`+|~+)[ \t]*$")? // null) as $close
        | (if $close != null and ($close.f[0:1] == $f[0:1]) and (($close.f | length) >= ($f | length))
           then .fence = null else . end)
        | .lines += [{text: $line}]
      end)
  | .lines
  | ([.[] | .heading // empty | .h | length] | min // ($parent + 1)) as $min
  | ([0, $parent + 1 - $min] | max) as $by
  | map(if .heading == null then .text
        else .heading | .i + ([range([(.h | length) + $by, 6] | min)] | map("#") | join("")) + .rest
        end)
  | join("\n");

# A body as GitHub returns it (CRLF line endings when it was typed in the web
# UI), ready to embed under a heading of level $parent.
def body_at($parent; $placeholder):
  (. // "") | gsub("\r\n"; "\n") | text_or($placeholder) | nest_headings($parent);

def plural($n; $word): "\($n) \($word)" + (if $n == 1 then "" else "s" end);

# --- header ---------------------------------------------------------------

def state_label($issue; $pull):
  if $pull != null then
    if $pull.merged then "Merged"
    elif $issue.state == "closed" then "Closed"
    elif $pull.draft then "Draft"
    else "Open"
    end
  elif $issue.state == "closed" then
    if $issue.state_reason == "not_planned" then "Closed (not planned)"
    elif $issue.state_reason == "duplicate" then "Closed (duplicate)"
    else "Closed (completed)"
    end
  else "Open"
  end;

def header_rows($issue; $pull):
  ($issue.html_url | sub("/(issues|pull)/[0-9]+$"; "")) as $repo_url
  | ($repo_url | sub("^https?://[^/]+/"; "")) as $repo
  | [
      ["Repository", "[\($repo | cell)](\($repo_url))"],
      [(if $pull != null then "Pull request" else "Issue" end), "[#\($issue.number)](\($issue.html_url))"],
      ["State", state_label($issue; $pull)],
      ["Author", ($issue.user | who)],
      ["Opened", ($issue.created_at | ts)],
      (if $pull != null and $pull.merged then
        ["Merged", "\($pull.merged_at | ts) by \($pull.merged_by | who)"]
      elif $issue.closed_at != null then
        ["Closed", ($issue.closed_at | ts)
          + (if $issue.closed_by != null then " by \($issue.closed_by | who)" else "" end)]
      else empty end),
      (if $pull != null then
        ["Branches", "`\($pull.head.label | cell)` → `\($pull.base.label | cell)`"]
      else empty end),
      (if ($issue.labels // []) | length > 0 then
        ["Labels", ($issue.labels | map(.name | cell) | join(", "))]
      else empty end),
      (if ($issue.assignees // []) | length > 0 then
        ["Assignees", ($issue.assignees | map(who) | join(", "))]
      else empty end),
      (if $pull != null and (($pull.requested_reviewers // []) | length > 0) then
        ["Review requested", ($pull.requested_reviewers | map(who) | join(", "))]
      else empty end),
      (if $issue.milestone != null then ["Milestone", ($issue.milestone.title | cell)] else empty end),
      (if $pull != null then
        ["Changes", "\(plural($pull.commits; "commit")), \(plural($pull.changed_files; "file")), +\($pull.additions) −\($pull.deletions)"]
      else empty end),
      ["Last updated", ($issue.updated_at | ts)]
    ];

def header($issue; $pull):
  "| | |\n|---|---|\n"
  + (header_rows($issue; $pull) | map("| **\(.[0])** | \(.[1]) |") | join("\n"));

# --- conversation ---------------------------------------------------------

# GitHub's diff_hunk runs from the hunk header down to the commented line,
# which for a comment far into a long hunk is dozens of lines the reader
# doesn't need. Keep the header and the last few lines, like the web UI does.
def trimmed_hunk:
  (split("\n")) as $lines
  | if ($lines | length) <= 12 then $lines | join("\n")
    else ([$lines[0], "..."] + $lines[-8:]) | join("\n")
    end;

def location:
  (.line // .original_line) as $last
  | (.start_line // .original_start_line) as $first
  | "`\(.path | cell)`"
    + (if $last == null then ""
       elif $first != null and $first != $last then " (lines \($first)–\($last))"
       else " (line \($last))"
       end)
    + (if .line == null then " — _outdated_" else "" end);

def thread($all):
  . as $root
  | ($root.diff_hunk // "" | trimmed_hunk) as $hunk
  | "#### \($root | location)\n\n"
    + (if $hunk != "" then
        fence($hunk) as $f | "\($f)diff\n\($hunk)\n\($f)\n\n"
       else "" end)
    + ([$root] + ($all | map(select(.in_reply_to_id == $root.id)) | sort_by(.created_at))
       | map("**\(.user | who)** on \(.created_at | ts):\n\n\(.body | body_at(4; "_No comment._"))")
       | join("\n\n"));

def review_verb:
  if .state == "APPROVED" then "approved these changes"
  elif .state == "CHANGES_REQUESTED" then "requested changes"
  elif .state == "DISMISSED" then "reviewed (dismissed)"
  else "reviewed"
  end;

def comment_entry:
  {at: .created_at,
   md: "### \(.user | who) commented on \(.created_at | ts)\n\n\(.body | body_at(3; "_No comment._"))"};

def review_entry($all):
  . as $review
  | ($all | map(select(.pull_request_review_id == $review.id and .in_reply_to_id == null))
          | sort_by(.path, (.line // .original_line // 0))) as $roots
  | if .state == "PENDING" then empty
    # A plain "COMMENTED" review with no text and no threads of its own is
    # what GitHub records when someone only *replies* to an existing thread;
    # that reply is already shown under the thread it belongs to.
    elif .state == "COMMENTED" and ((.body // "") | test("^\\s*$")) and ($roots | length == 0) then empty
    else
      {at: .submitted_at,
       md: ("### \(.user | who) \(review_verb) on \(.submitted_at | ts)"
            + (if (.body // "") | test("^\\s*$") then "" else "\n\n\(.body | body_at(3; ""))" end)
            + ($roots | map("\n\n" + thread($all)) | join("")))}
    end;

# --- PR summary tables ----------------------------------------------------

def commits_section($commits; $pull):
  if ($commits | length) == 0 then empty
  else
    "## Commits (\($pull.commits))\n\n"
    + (if $pull.commits > ($commits | length) then
        "_Showing the first \($commits | length); the GitHub API lists at most 250 commits per pull request._\n\n"
       else "" end)
    + "| Commit | Message | Author | Date |\n|---|---|---|---|\n"
    + ($commits
       | map("| `\(.sha[0:7])` | \(.commit.message | split("\n")[0] | cell) | "
             + "\(if .author != null then (.author | who) else (.commit.author.name // "unknown" | cell) end) | "
             + "\(.commit.author.date | ts) |")
       | join("\n"))
  end;

def files_section($files; $pull):
  if ($files | length) == 0 then empty
  else
    "## Changed files (\($pull.changed_files))\n\n"
    + (if $pull.changed_files > ($files | length) then
        "_Showing the first \($files | length)._\n\n"
       else "" end)
    + "| File | Status | Added | Removed |\n|---|---|--:|--:|\n"
    + ($files
       | map("| "
             + (if .previous_filename != null and .previous_filename != .filename then
                 "`\(.previous_filename | cell)` → `\(.filename | cell)`"
                else "`\(.filename | cell)`" end)
             + " | \(.status) | +\(.additions) | −\(.deletions) |")
       | join("\n"))
  end;

# --- document -------------------------------------------------------------

# $issue is GET /repos/O/R/issues/N, and $comments that issue's comments, all
# pages concatenated. For a pull request, $pull is GET .../pulls/N and the
# remaining arguments are its reviews, review comments, commits and files;
# for an issue, $pull is null and the rest are []. $url is what the user
# passed in, recorded as-is in the front matter.
def github_md($url; $issue; $pull; $comments; $reviews; $review_comments; $commits; $files):
  ($issue.html_url | sub("/(issues|pull)/[0-9]+$"; "") | sub("^https?://[^/]+/"; "")) as $repo
  | ([($comments[] | comment_entry), ($reviews[] | review_entry($review_comments))]
     | sort_by(.at)) as $conversation
  | [
      # A JSON string is also a valid YAML double-quoted scalar, which makes
      # tojson the escaping a title full of quotes and colons needs here.
      "---",
      "title: \("\($issue.title) #\($issue.number)" | tojson)",
      "source_url: \($url | tojson)",
      "github_repository: \($repo | tojson)",
      "github_number: \($issue.number)",
      "github_kind: \(if $pull != null then "pull_request" else "issue" end | tojson)",
      "---",
      "",
      header($issue; $pull),
      "",
      "## Description",
      "",
      "_\($issue.user | who) opened this on \($issue.created_at | ts)_",
      "",
      ($issue.body | body_at(2; "_No description provided._")),
      "",
      (if ($conversation | length) > 0 then
        "## Conversation\n\n" + ($conversation | map(.md) | join("\n\n")) + "\n"
       else empty end),
      (commits_section($commits; $pull) | . + "\n"),
      (files_section($files; $pull) | . + "\n")
    ]
  | join("\n");
