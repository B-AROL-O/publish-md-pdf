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

output_dir="$PWD"
output_name=""

while [ $# -gt 0 ]; do
	case "$1" in
	--output-dir)
		[ $# -ge 2 ] || {
			echo "ERROR: --output-dir requires an argument"
			exit 1
		}
		output_dir="$2"
		shift 2
		;;
	--output-name)
		[ $# -ge 2 ] || {
			echo "ERROR: --output-name requires an argument"
			exit 1
		}
		output_name="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		break
		;;
	-*)
		echo "ERROR: Unknown option: $1"
		usage
		exit 1
		;;
	*)
		break
		;;
	esac
done

if [ $# -eq 0 ]; then
	usage
	exit 1
fi

if [ -n "$output_name" ] && [ $# -gt 1 ]; then
	echo "ERROR: --output-name can only be used with a single input file"
	exit 1
fi

if ! command -v pandoc >/dev/null 2>&1; then
	echo "ERROR: 'pandoc' is not installed. Install it with: sudo apt-get install -y pandoc"
	exit 1
fi

mkdir -p "$output_dir"

for confluence_file in "$@"; do
	if [ ! -f "$confluence_file" ]; then
		echo "ERROR: File not found: $confluence_file"
		exit 1
	fi
	if [ "${confluence_file##*.}" != "confluence" ]; then
		echo "ERROR: Not a Confluence Storage Format (.confluence) file: $confluence_file"
		exit 1
	fi

	if [ -n "$output_name" ]; then
		out_name="$output_name"
		case "$out_name" in
		*.md) ;;
		*) out_name="$out_name.md" ;;
		esac
	else
		out_name="$(basename "${confluence_file%.confluence}").md"
	fi
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
