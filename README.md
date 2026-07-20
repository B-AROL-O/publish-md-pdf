# publish-md-pdf

Render Markdown files to A4-sized PDF, using [pandoc](https://pandoc.org/) with the
[WeasyPrint](https://weasyprint.org/) PDF engine. By default, each `<file>.md` is written as
`<file>.pdf` into the current working directory.

Shipped as a container image (`ghcr.io/b-arol-o/publish-md-pdf`) and as a Docker-based GitHub Action,
so it can be used both as a local CLI (via `docker run`) and in CI.

## Usage

### As a CLI (via Docker)

```bash
docker run --rm -v "$PWD:/workspace" ghcr.io/b-arol-o/publish-md-pdf:v1 \
  [--output-dir DIR] [--output-name NAME] [--css-file FILE] <file.md> [file2.md ...]
```

- `--output-dir DIR` — directory to write the PDF(s) into (default: `/workspace`, i.e. the mounted
  `$PWD`). Created if it doesn't already exist.
- `--output-name NAME` — filename for the generated PDF (default: derived from the input `.md`
  filename). Only valid when converting a single input file. `.pdf` is appended automatically if not
  already present.
- `--css-file FILE` — style sheet to use (default: the image's built-in `publish-md-pdf.css`). A
  custom style sheet should keep the `.task-checkbox` rules from the default one (see
  [Notes](#notes)) if the source Markdown has GFM task lists (`- [ ]` / `- [x]`).

Paths outside `$PWD` (a different `--output-dir`, a custom `--css-file`) need their own bind mount,
since the script only sees paths inside the container.

### As a GitHub Action

```yaml
- uses: B-AROL-O/publish-md-pdf@v1
  with:
    files: docs/report.md
    output-dir: dist
```

| Input         | Required | Description                                                   |
| ------------- | -------- | ------------------------------------------------------------- |
| `files`       | yes      | Space-separated list of Markdown files to convert             |
| `output-dir`  | no       | Directory to write the PDF(s) into (default: repository root) |
| `output-name` | no       | Filename for the PDF; only valid with a single input file     |
| `css-file`    | no       | Path to a custom style sheet, relative to the repository root |

Uploading or committing the resulting PDF(s) is the consumer's job (e.g. `actions/upload-artifact`).

## Building the image locally

```bash
docker build -t publish-md-pdf .
docker run --rm -v "$PWD:/workspace" publish-md-pdf sample.md
```

## Notes

- Page layout (A4 size, margins, page-number footer, code-block wrapping) is defined in
  `publish-md-pdf.css`.
- Task-list checkboxes (`- [ ]` / `- [x]`) are rendered as `<span class="task-checkbox">` markers
  instead of native `<input type="checkbox">` elements, because WeasyPrint always fills a checked
  native checkbox solid black and ignores CSS overrides on it. A custom `--css-file` needs its own
  `.task-checkbox` / `.task-checkbox.checked` rules to render task lists (see `publish-md-pdf.css`
  for a working example); otherwise the checkboxes render as empty, unstyled markers.
- If the Markdown file has a YAML front matter `title:` field, it is used as the PDF's document title
  metadata.

## License

[MIT](LICENSE)

<!-- EOF -->
