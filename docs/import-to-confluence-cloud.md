# Importing a `.confluence` (or `.md`) file into Confluence Cloud

This HOWTO covers how to get the output of `--format confluence` — or the
source `.md` it was generated from — into a real Confluence Cloud page.
Going the other way — fetching an existing Confluence Cloud page straight
from its URL — is `--format md`/`pdf`/`confluence` with a URL as the input;
see the
[main README's Importing a Confluence page by URL section](../README.md#importing-a-confluence-page-by-url).

There are two supported paths, depending on how much fidelity you need:

- **[Method A — Paste rendered HTML via the web UI](#method-a--paste-rendered-html-via-the-web-ui)**
  Practical, no admin access or credentials needed, good for one-off pages.
  Some elements (code block language, task checkboxes, internal anchors)
  need manual touch-up afterward.
- **[Method B — REST API with the `.confluence` file](#method-b--rest-api-with-the-confluence-file)**
  Byte-for-byte fidelity to the storage-format XHTML this repository generates.
  Requires an API token and a few `curl` commands, but no manual cleanup.

Confluence Cloud's standard web editor has no built-in way to paste raw
storage-format XHTML (the `<ac:structured-macro>` markup in `.confluence`
files) directly — that gap is exactly why Method B exists as the officially
supported route for this content.

## Method A — paste rendered HTML via the web UI

Use the original `.md` file for this method, not `.confluence` — the browser
needs to render standard HTML tags to convert them on paste, and it won't
understand Confluence-specific macro elements.

### 1. Render the Markdown to plain HTML

```bash
pandoc README.md -o /tmp/readme.html --standalone
```

> **Running this inside WSL2?** `/tmp` is inside the Linux filesystem, and a
> Windows browser can't open `file:///tmp/readme.html` — that path doesn't
> exist on Windows. Either write the output under your repo checkout (which
> is already on the Windows-visible `/mnt/c/...` mount), e.g.
> `pandoc README.md -o "$PWD/readme.html" --standalone`, and then open
> `C:\path\to\your\repo\readme.html` in the Windows browser; or open
> `\\wsl.localhost\<distro-name>\tmp\readme.html` in the Windows browser's
> address bar instead.

### 2. Open it in a browser and copy everything

Open the rendered HTML file in a real browser tab and confirm it actually
**renders** as a formatted page — headings, styled paragraphs, etc. — not
raw `<tags>` as literal text. If you see literal markup, you're looking at
the file's source (e.g. via `cat`, a text editor, or a `view-source:` URL)
rather than the browser-rendered DOM, and copying from there will paste as
a plain-text code block in Confluence instead of converting to native
blocks.

Once it's rendering correctly, select all (`Ctrl+A`) and copy (`Ctrl+C`).

### 3. Create the page in Confluence Cloud

1. Go to the target space.
2. Click **Create** → **Blank page**.
3. Enter a title.
4. Click into the page body.

### 4. Paste

`Ctrl+V`. Confluence's editor parses the clipboard HTML and converts it into
native blocks.

### 5. What carries over cleanly

- Headings
- Paragraphs
- Bullet and numbered lists
- Tables
- Links
- Bold / italic

### 6. What needs manual touch-up

- **Code block language** — fenced code blocks (` ```bash `,
  ` ```yaml `) usually paste as a Code Block macro, but the language
  often isn't preserved from plain HTML. Click each code block and set the
  language dropdown manually.
- **Task list checkboxes** (`- [ ]` / `- [x]`) — these may paste as plain
  bullet text rather than Confluence's native task items. It's usually
  easier to delete those lines and retype them using Confluence's `[]`
  editor shortcut, which creates real checked/unchecked task items.
- **Internal anchor links** (e.g. `#converting-tofrom-confluence`) — these
  point at heading IDs from the Markdown render and typically won't resolve
  to Confluence's own auto-generated heading anchors. Check each internal
  link after pasting and re-link if broken.

This is the standard "copy a rendered doc into Confluence" workflow and is
the least fiddly option for a one-off page where minor formatting drift is
acceptable.

## Method B — REST API with the `.confluence` file

This sends the storage-format XHTML from `--format confluence` verbatim, so
there's no drift: code blocks stay as `ac:structured-macro` code macros,
task-list ballot-box characters (`☐`/`☒`) come through as-is, etc. See the
[main README's Converting to/from Confluence section](../README.md#converting-tofrom-confluence)
for what this conversion does and does not preserve.

### 1. Get an API token

See [Confluence Cloud authentication](confluence-authentication.md) for how to find your account
email and create an API token. Export the token as an environment variable rather than pasting it
into commands directly:

```bash
export API_TOKEN=your-token-here
```

Requests below authenticate as `-u your-email@company.com:$API_TOKEN`.

### 2. Find the target space key

```bash
curl -s -u "you@company.com:$API_TOKEN" \
  "https://yoursite.atlassian.net/wiki/rest/api/space?limit=25" \
  | jq '.results[] | {key, name}'
```

### 3. Generate the `.confluence` file (if you haven't already)

```bash
docker run --rm -v "$PWD:/workspace" \
  ghcr.io/b-arol-o/publish-md-pdf:v2 \
  --format confluence \
  README.md
```

This writes `README.confluence` next to `README.md`.

### 4. Build the JSON payload

`jq --rawfile` handles the escaping of the XHTML content into the JSON
string safely:

```bash
jq -n --rawfile body README.confluence \
  '{
     type: "page",
     title: "publish-md-pdf",
     space: { key: "YOURSPACE" },
     body: {
       storage: {
         value: $body,
         representation: "storage"
       }
     }
   }' > /tmp/payload.json
```

Replace `YOURSPACE` with the space key from step 2, and the `title` with
whatever you want the page called.

### 5. Create the page

```bash
curl -s -u "you@company.com:$API_TOKEN" \
  -X POST \
  -H "Content-Type: application/json" \
  --data @/tmp/payload.json \
  "https://yoursite.atlassian.net/wiki/rest/api/content" | jq .
```

The response includes `"id"` and `"_links.webui"` — follow the latter
(prefixed with your site's base URL) to view the new page.

### 6. Updating an existing page instead

Confluence requires the current version number on every update, or the
request is rejected as stale:

```bash
PAGE_ID=123456

CURRENT_VERSION=$(curl -s -u "you@company.com:$API_TOKEN" \
  "https://yoursite.atlassian.net/wiki/rest/api/content/$PAGE_ID?expand=version" \
  | jq '.version.number')

jq -n --rawfile body README.confluence --argjson ver $((CURRENT_VERSION + 1)) \
  '{
     type: "page",
     title: "publish-md-pdf",
     version: { number: $ver },
     body: { storage: { value: $body, representation: "storage" } }
   }' > /tmp/payload.json

curl -s -u "you@company.com:$API_TOKEN" \
  -X PUT \
  -H "Content-Type: application/json" \
  --data @/tmp/payload.json \
  "https://yoursite.atlassian.net/wiki/rest/api/content/$PAGE_ID" | jq .
```

### Notes on fidelity

- Images become plain `<img src="...">` rather than Confluence's
  attachment-backed `ac:image` macro, since there's no attachment to point
  at in a file-only conversion. If the source Markdown has local image
  references, upload them as attachments separately and adjust `src` (or
  swap to `ac:image` macros) after import.
- A fenced code block with no language round-trips as an indented code
  block instead of a fenced one; this only affects presentation, not
  correctness.
- This only round-trips content produced by `--format confluence` /
  `--format md` — storage-format XHTML written by hand or exported from a
  real Confluence page may use macros or attributes these conversions
  don't recognize.

## Which method should I use?

|                                            | Method A (paste HTML)              | Method B (REST API)                               |
| ------------------------------------------ | ---------------------------------- | ------------------------------------------------- |
| Needs API token / credentials              | No                                 | Yes                                               |
| Needs `curl`/`jq`                          | No                                 | Yes                                               |
| Code block language preserved              | No (manual fix)                    | Yes                                               |
| Task checkboxes as native Confluence tasks | No (manual retype)                 | No (renders as ☐/☒ text — see limitations above)  |
| Internal anchor links preserved            | No (manual fix)                    | Usually, if heading IDs match Confluence's scheme |
| Good for                                   | Quick one-off page, minor drift OK | Scripted/repeatable imports, exact fidelity       |
