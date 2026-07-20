#!/bin/bash
# ==========================================================
# Docker/GitHub Action entrypoint: translates action inputs (passed as
# INPUT_<NAME> environment variables by the GitHub Actions runner) into
# publish-md-pdf.sh flags.
# ==========================================================

set -e

args=()

[ -n "$INPUT_OUTPUT_DIR" ] && args+=(--output-dir "$INPUT_OUTPUT_DIR")
[ -n "$INPUT_OUTPUT_NAME" ] && args+=(--output-name "$INPUT_OUTPUT_NAME")
[ -n "$INPUT_CSS_FILE" ] && args+=(--css-file "$INPUT_CSS_FILE")

if [ -z "$INPUT_FILES" ]; then
	echo "ERROR: 'files' input is required"
	exit 1
fi

# Intentional word-splitting: INPUT_FILES is a space-separated file list.
# shellcheck disable=SC2206
args+=($INPUT_FILES)

exec /usr/local/bin/publish-md-pdf.sh "${args[@]}"

# EOF
