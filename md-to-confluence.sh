#!/bin/bash
# ==========================================================
# DEPRECATED compatibility shim.
#
# Markdown to Confluence Storage Format is now a --format on the single
# publish-md-pdf.sh entry point. This wrapper forwards to it so v1 callers
# using `docker run --entrypoint /usr/local/bin/md-to-confluence.sh ...`
# keep working; it will be removed in v3.0.0.
# ==========================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "WARNING: md-to-confluence.sh is deprecated and will be removed in v3.0.0." >&2
echo "WARNING: Use 'publish-md-pdf.sh --format confluence' instead." >&2

exec "$SCRIPT_DIR/publish-md-pdf.sh" --format confluence "$@"

# EOF
