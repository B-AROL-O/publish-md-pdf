#!/bin/bash
# ==========================================================
# GitHub Action entrypoint: translates action inputs (passed as INPUT_<NAME>
# environment variables by the GitHub Actions runner) into publish-md-pdf.sh
# flags.
#
# This is a pure translation layer — every input maps 1:1 onto a flag, and
# the 'format' input maps onto --format. Which conversion runs is decided by
# publish-md-pdf.sh alone, so the CLI and the Action share one code path.
# ==========================================================

set -e

args=()

# GitHub Actions exports hyphenated input names with the hyphen preserved
# (e.g. INPUT_OUTPUT-DIR, not INPUT_OUTPUT_DIR), which isn't a valid bash
# identifier, so it must be read via printenv rather than "$INPUT_...".
format="$(printenv 'INPUT_FORMAT' || true)"
output_dir="$(printenv 'INPUT_OUTPUT-DIR' || true)"
output_name="$(printenv 'INPUT_OUTPUT-NAME' || true)"
css_file="$(printenv 'INPUT_CSS-FILE' || true)"
attachments="$(printenv 'INPUT_ATTACHMENTS' || true)"

[ -n "$format" ] && args+=(--format "$format")
[ -n "$output_dir" ] && args+=(--output-dir "$output_dir")
[ -n "$output_name" ] && args+=(--output-name "$output_name")
[ -n "$css_file" ] && args+=(--css-file "$css_file")
# The only boolean input, and the only one that isn't a value passed straight
# through: the flag it maps onto is the off switch, so it's added only when
# the input turns the default behavior off.
[ "$attachments" = "false" ] && args+=(--no-attachments)

if [ -z "$INPUT_FILES" ]; then
	echo "ERROR: 'files' input is required"
	exit 1
fi

# Intentional word-splitting: INPUT_FILES is a space-separated file list.
# shellcheck disable=SC2206
args+=($INPUT_FILES)

exec /usr/local/bin/publish-md-pdf.sh "${args[@]}"

# EOF
