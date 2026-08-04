#!/bin/bash
# ==========================================================
# Convert one or more Confluence Storage Format fragments (as produced by
# md-to-confluence.sh, or copied out of a Confluence page's
# body.storage.value) back to Markdown.
#
# Requires: pandoc
#   sudo apt-get install -y pandoc
#
# Usage: scripts/confluence-to-md.sh [--output-dir DIR] [--output-name NAME] <file.confluence> [file2.confluence ...]
# By default each <file>.confluence is rendered to <file>.md in $PWD; use
# --output-dir and/or --output-name to write elsewhere or under a different
# name.
# ==========================================================

set -e
# set -x

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cli-common.sh
source "$SCRIPT_DIR/cli-common.sh"

usage() {
	echo "Usage: $0 [--output-dir DIR] [--output-name NAME] <file.confluence> [file2.confluence ...]"
	echo "Converts each Confluence Storage Format fragment to Markdown."
	echo
	echo "  --output-dir DIR    Directory to write the .md file(s) into (default: \$PWD)"
	echo "  --output-name NAME  Filename for the output (default: <file>.md); only"
	echo "                      valid when converting a single input file"
}

# Reverses emit_code_macro()'s CDATA-split and entity escaping, then
# re-escapes the raw code text as HTML so pandoc's HTML reader turns it back
# into a real fenced code block.
emit_code_block() {
	local lang="$1" text="$2"
	text="${text//]]]]><![CDATA[>/]]>}"
	text="${text//&/\&amp;}"
	text="${text//</\&lt;}"
	text="${text//>/\&gt;}"

	if [ -n "$lang" ]; then
		printf '<pre class="%s"><code>%s</code></pre>\n' "$lang" "$text"
	else
		printf '<pre><code>%s</code></pre>\n' "$text"
	fi
}

# Streams a Confluence Storage Format fragment, rewriting each "code"
# structured macro (md-to-confluence.sh's output shape) back into a plain
# <pre><code> block pandoc's HTML reader understands. Mirrors
# convert_code_blocks() in md-to-confluence.sh: the opening tag and the first
# content line share a line, and the closing tags are appended directly to
# the last content line.
restore_code_blocks() {
	local in_code=0 lang="" buf="" line rest

	while IFS='' read -r line || [ -n "$line" ]; do
		if [ "$in_code" -eq 0 ]; then
			if [[ "$line" =~ ^\<ac:structured-macro\ ac:name=\"code\"\ ac:schema-version=\"1\"\>(\<ac:parameter\ ac:name=\"language\"\>([^\<]*)\</ac:parameter\>)?\<ac:plain-text-body\>\<!\[CDATA\[(.*)$ ]]; then
				lang="${BASH_REMATCH[2]}"
				rest="${BASH_REMATCH[3]}"
				if [[ "$rest" == *"]]></ac:plain-text-body></ac:structured-macro>" ]]; then
					emit_code_block "$lang" "${rest%]]></ac:plain-text-body></ac:structured-macro>}"
				else
					in_code=1
					buf="$rest"
				fi
				continue
			fi
			printf '%s\n' "$line"
			continue
		fi

		if [[ "$line" == *"]]></ac:plain-text-body></ac:structured-macro>" ]]; then
			buf+=$'\n'"${line%]]></ac:plain-text-body></ac:structured-macro>}"
			emit_code_block "$lang" "$buf"
			in_code=0
			buf=""
		else
			buf+=$'\n'"$line"
		fi
	done <"$1"
}

parse_common_flags "$@"
require_command pandoc "sudo apt-get install -y pandoc"
mkdir -p "$output_dir"

for confluence_file in "${remaining_args[@]}"; do
	require_file_with_ext "$confluence_file" confluence "Confluence Storage Format (.confluence)"
	out_name="$(resolve_output_name "$confluence_file" confluence md "$output_name")"
	out_file="$output_dir/$out_name"
	tmp_html="$(mktemp --suffix=.html)"

	echo "INFO: Converting $confluence_file -> $out_file"

	restore_code_blocks "$confluence_file" >"$tmp_html"

	if ! pandoc_output=$(pandoc "$tmp_html" \
		--from=html \
		--to=gfm \
		--wrap=none \
		-o "$out_file" 2>&1); then
		echo "$pandoc_output"
		echo "ERROR: pandoc failed to convert $confluence_file"
		rm -f "$tmp_html"
		exit 1
	fi
	echo "$pandoc_output"

	rm -f "$tmp_html"
	echo "INFO: Wrote $out_file ($(du -h "$out_file" | cut -f1))"
done

# EOF
