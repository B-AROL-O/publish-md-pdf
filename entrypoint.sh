#!/bin/bash
# ==========================================================
# Docker/GitHub Action entrypoint: translates action inputs (passed as
# INPUT_<NAME> environment variables by the GitHub Actions runner) into
# publish-md-pdf.sh flags.
# ==========================================================

set -e

args=()

# GitHub Actions exports hyphenated input names with the hyphen preserved
# (e.g. INPUT_OUTPUT-DIR, not INPUT_OUTPUT_DIR), which isn't a valid bash
# identifier, so it must be read via printenv rather than "$INPUT_...".
output_dir="$(printenv 'INPUT_OUTPUT-DIR' || true)"
output_name="$(printenv 'INPUT_OUTPUT-NAME' || true)"
css_file="$(printenv 'INPUT_CSS-FILE' || true)"

[ -n "$output_dir" ] && args+=(--output-dir "$output_dir")
[ -n "$output_name" ] && args+=(--output-name "$output_name")
[ -n "$css_file" ] && args+=(--css-file "$css_file")

if [ -z "$INPUT_FILES" ]; then
	echo "ERROR: 'files' input is required"
	exit 1
fi

# Intentional word-splitting: INPUT_FILES is a space-separated file list.
# shellcheck disable=SC2206
args+=($INPUT_FILES)

exec /usr/local/bin/publish-md-pdf.sh "${args[@]}"

# EOF
