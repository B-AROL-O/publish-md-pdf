# AGENTS.md

This file provides guidance to AI coding agents (including Claude Code at claude.ai/code) when
working with code in this repository. `CLAUDE.md` is a symlink to this file.

## What this is

`publish-md-pdf` converts between Markdown, PDF, and Confluence Storage Format, shipped as a
Docker image (`ghcr.io/b-arol-o/publish-md-pdf`) and a Docker-based GitHub Action. Bash only — no
package.json, no unit test framework.

## Commands

Build the image (the tag must match `runs.image` in `action.yml` for the "Action self-test" CI
steps to resolve locally instead of pulling the published one):

```bash
docker build -t ghcr.io/b-arol-o/publish-md-pdf:v2 .
```

Run a conversion (`<file>.md` writes `<file>.pdf` into `$PWD` by default):

```bash
docker run --rm -v "$PWD:/workspace" ghcr.io/b-arol-o/publish-md-pdf:v2 sample.md
docker run --rm -v "$PWD:/workspace" ghcr.io/b-arol-o/publish-md-pdf:v2 --format confluence sample.md
docker run --rm -v "$PWD:/workspace" ghcr.io/b-arol-o/publish-md-pdf:v2 --format md sample.confluence
```

Or against the scripts directly on a host with `pandoc`/`weasyprint` installed:

```bash
./publish-md-pdf.sh --format pdf sample.md
```

There is no unit test suite; correctness is verified by the integration steps in
`.github/workflows/ci.yml`, each an independent `docker run` plus an assertion. To run one of those
checks locally, build the image first, then copy the relevant step's commands — e.g. the Mermaid
rendering check:

```bash
docker run --rm -v "$PWD:/workspace" ghcr.io/b-arol-o/publish-md-pdf:v2 sample-mermaid.md
pdftotext sample-mermaid.pdf - | grep -q erDiagram && echo "FAIL: rendered as literal code, not an image"
```

Linting is `super-linter/slim` over the whole codebase (`.github/workflows/lint.yml`,
`VALIDATE_ALL_CODEBASE: true`), plus `.markdownlint.json` (120-char line length, tables/code blocks
exempt) and `biome.json` (2-space indent) for any JSON/JS. There's no local lint script; the
fastest local check for a shell change is `shellcheck lib/*.sh publish-md-pdf.sh entrypoint.sh`.

## Architecture

One entry point, `publish-md-pdf.sh`; `--format` (`pdf` | `confluence` | `md`) selects the
conversion. The GitHub Action reaches the same flags through `entrypoint.sh`, which only
translates `INPUT_*` environment variables into flags and makes no routing decisions of its own —
the CLI and the Action always share one code path.

Conversion modules live in `lib/` and are _sourced_, not executed, by `publish-md-pdf.sh`. Each
format exposes exactly two functions the main script calls by convention —
`convert_<format>_init` (one-time tool checks/setup) and `convert_<format>_file <in> <out>` — so
adding a format means adding a module plus one row to the `case "$format"` block in
`publish-md-pdf.sh`. `lib/common.sh` holds what every module shares: `require_command`,
`require_file_with_ext`, `resolve_output_name`.

- `lib/convert-pdf.sh` — pandoc (gfm → HTML5) then WeasyPrint. Two WeasyPrint-specific
  workarounds live here: native `<input type=checkbox>` is swapped for
  `<span class="task-checkbox">` (WeasyPrint always fills a checked native checkbox solid black,
  ignoring CSS), and `--no-highlight` is passed to pandoc (WeasyPrint doesn't cancel pandoc's
  default syntax-highlight indent CSS the way browsers do). Mermaid fenced code blocks are
  rendered to PNG via `mermaid-filter.lua` (a pandoc Lua filter that shells out to mermaid-cli's
  `mmdc`) when `mmdc` is on `PATH`; otherwise they silently fall back to plain code.
- `lib/convert-confluence.sh` — pandoc (gfm → HTML5) then a line-oriented post-process
  (`convert_confluence_code_blocks`) that rewrites pandoc's `<pre><code>` blocks into Confluence's
  `<ac:structured-macro ac:name="code">` XHTML, and rewrites checkbox `<input>` elements into the
  ☐/☒ characters pandoc's own gfm _writer_ recognizes as task-list markers — which is what makes
  the reverse conversion below possible.
- `lib/convert-md.sh` — the reverse: `convert_md_restore_code_blocks` rewrites Confluence code
  macros back into `<pre><code>` before handing the fragment to pandoc's HTML reader (gfm output).

  Both code-block rewriters are line-oriented state machines, not a regular expression over the
  whole file, because pandoc always keeps a block's opening tag and first content line on one
  line, and its closing tag glued to the last content line with no intervening newline. The two
  are mirror images of each other — read the comments in both before changing the matching logic
  in either.

  `lib/convert-md.sh` also has `convert_md_rewrite_objects`, applied to every non-code line
  alongside the code-block scanner: it rewrites `<ac:image>` (attachment- or URL-backed) and
  `<ac:link>` (attachment-backed only — a link to another page, `ri:page`, has no local target and
  is left alone) into plain `<img>`/`<a>`, since pandoc's HTML reader otherwise discards those
  elements silently. It's a hand-rolled scanner rather than a regular expression for the same reason as the two
  code-block rewriters — several objects routinely share one line in a storage body fetched from
  the API — plus one more: `<ac:image>` can wrap an `<ac:caption>` holding arbitrary XHTML, which
  neither a lazy nor a greedy single pattern handles correctly.

- `lib/fetch-confluence.sh` also has `confluence_fetch_attachments`, which downloads every
  attachment of a fetched page and fills `CONFLUENCE_ATTACHMENT_MAP` (declared in `lib/common.sh`,
  since `convert-md.sh` reads it) so the rewriter above can point at where each one landed. Two
  things here are load-bearing, not incidental: `confluence_attachment_url` refuses a
  `downloadLink` that doesn't resolve to the page's own origin, because it's fetched with the same
  credentialed `curl` config as everything else in this module — an unpinned link would hand the
  Confluence API token to whatever host the response named, the same class of leak as
  `.claude/memory/feedback_curl_url_effective_leaks_credentials.md`, one layer up; and
  `confluence_safe_basename` (in `lib/common.sh`) sanitizes an attachment's title before it's used
  as a filename, since that title is server-controlled text this tool writes straight to disk.

Two scripts, `md-to-confluence.sh` and `confluence-to-md.sh`, are deprecated v1 compatibility
shims kept only so `docker run --entrypoint ...` invocations from before the v2 `--format` flag
still work; they forward to `publish-md-pdf.sh --format ...` and print a deprecation warning on
stderr. Removal is planned for v3.0.0 — don't add new behavior to them.

`--css-file` is only valid with `--format pdf`; the main script rejects it otherwise. A custom
style sheet needs its own `.task-checkbox` / `.task-checkbox.checked` rules (see
`publish-md-pdf.css`) or task lists render as unstyled, empty markers.

`--no-attachments` skips downloading a fetched page's attachments (`entrypoint.sh` maps the
Action's boolean `attachments` input onto it — the one input that isn't a plain passthrough, since
the flag it maps to is the off switch). `--format confluence` never downloads them regardless of
this flag: a saved `.confluence` file is expected to keep referencing attachments the way a real
Confluence page does, for re-uploading elsewhere, so it's the one format `publish-md-pdf.sh`'s
conversion loop special-cases rather than wiring generically. `sample-attachments.confluence`
exercises the rewriter and the downloader together, including the two adversarial fixtures
(a directory-traversal title, a cross-origin `downloadLink`) — see the CI steps under "Confluence
URL import" following it in `.github/workflows/ci.yml` before changing either.

## Documentation

- `README.md` is the primary reference for usage, the Confluence conversion's known fidelity
  limitations, and Mermaid rendering notes — read it before re-deriving any of that from the
  scripts.
- `docs/import-to-confluence-cloud.md` — getting a generated `.confluence` file (or its source
  `.md`) into a real Confluence Cloud page, via the web UI or the REST API.
- `docs/confluence-authentication.md` — obtaining and rotating the Confluence Cloud API token and
  account email these tools need.

## Persistent notes

`.claude/memory/MEMORY.md` accumulates feedback and lessons from past sessions in this repository
(e.g. security pitfalls found while testing against a real Confluence instance). It isn't loaded
automatically — check it explicitly at the start of work that touches an area it might cover.
