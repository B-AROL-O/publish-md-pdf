# Sample document

This file exercises the two known WeasyPrint rendering traps, and is used by CI as a smoke test:
native GFM task-list checkboxes, and fenced code blocks.

## Task list

- [x] Render Markdown to HTML with pandoc
- [x] Rewrite task-list checkboxes as styled `<span>` markers
- [ ] Render HTML to PDF with WeasyPrint

## Fenced code block

```bash
#!/bin/bash
echo "Hello from publish-md-pdf"
```

## Table

| Column A | Column B |
| --- | --- |
| foo | bar |
| baz | qux |

<!-- EOF -->
