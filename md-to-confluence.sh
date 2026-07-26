#!/bin/bash
# ==========================================================
# Convert one or more Markdown files to Confluence Storage Format (the
# XHTML-based fragment used by the Confluence REST API's body.storage.value
# field).
#
# Requires: pandoc
#   sudo apt-get install -y pandoc
#
# Usage: scripts/md-to-confluence.sh [--output-dir DIR] [--output-name NAME] <file.md> [file2.md ...]
# By default each <file>.md is rendered to <file>.confluence in $PWD; use
# --output-dir and/or --output-name to write elsewhere or under a different
# name.
# ==========================================================

set -e
# set -x

apos="'"

usage() {
	echo "Usage: $0 [--output-dir DIR] [--output-name NAME] <file.md> [file2.md ...]"
	echo "Converts each Markdown file to a Confluence Storage Format fragment."
	echo
	echo "  --output-dir DIR    Directory to write the .confluence file(s) into"
	echo "                      (default: \$PWD)"
	echo "  --output-name NAME  Filename for the output (default: <file>.confluence);"
	echo "                      only valid when converting a single input file"
}

# Rewrites the raw text captured from a pandoc <pre><code> block into a
# Confluence "code" structured macro: un-escape the HTML entities pandoc
# used, then re-escape a literal "]]>" so it can't terminate the CDATA
# section early (the standard "split the CDATA" trick).
emit_code_macro() {
	local lang="$1" text="$2"
	text="${text//&lt;/<}"
	text="${text//&gt;/>}"
	text="${text//&quot;/\"}"
	text="${text//&#39;/$apos}"
	text="${text//&amp;/\&}"
	text="${text//]]>/]]]]><![CDATA[>}"

	printf '<ac:structured-macro ac:name="code" ac:schema-version="1">'
	if [ -n "$lang" ]; then
		printf '<ac:parameter ac:name="language">%s</ac:parameter>' "$lang"
	fi
	printf '<ac:plain-text-body><![CDATA[%s]]></ac:plain-text-body></ac:structured-macro>\n' "$text"
}

# Streams a pandoc HTML5 fragment, rewriting each <pre[ class="LANG"]><code>...
# </code></pre> block (pandoc's shape for a fenced code block) into a
# Confluence code macro. pandoc always keeps the opening tag and the first
# content line on one line, and appends the closing tag directly to the last
# content line with no newline in between, so both ends are detected with a
# single line-oriented scan.
convert_code_blocks() {
	local html_file="$1"
	local in_code=0 lang="" buf="" line rest

	while IFS='' read -r line || [ -n "$line" ]; do
		if [ "$in_code" -eq 0 ]; then
			if [[ "$line" =~ ^\<pre(\ class=\"([^\"]*)\")?\>\<code\>(.*)$ ]]; then
				lang="${BASH_REMATCH[2]}"
				rest="${BASH_REMATCH[3]}"
				if [[ "$rest" == *"</code></pre>" ]]; then
					emit_code_macro "$lang" "${rest%</code></pre>}"
				else
					in_code=1
					buf="$rest"
				fi
				continue
			fi
			printf '%s\n' "$line"
			continue
		fi

		if [[ "$line" == *"</code></pre>" ]]; then
			buf+=$'\n'"${line%</code></pre>}"
			emit_code_macro "$lang" "$buf"
			in_code=0
			buf=""
		else
			buf+=$'\n'"$line"
		fi
	done <"$html_file"
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

for md_file in "$@"; do
	if [ ! -f "$md_file" ]; then
		echo "ERROR: File not found: $md_file"
		exit 1
	fi
	if [ "${md_file##*.}" != "md" ]; then
		echo "ERROR: Not a Markdown (.md) file: $md_file"
		exit 1
	fi

	if [ -n "$output_name" ]; then
		out_name="$output_name"
		case "$out_name" in
		*.confluence) ;;
		*) out_name="$out_name.confluence" ;;
		esac
	else
		out_name="$(basename "${md_file%.md}").confluence"
	fi
	out_file="$output_dir/$out_name"
	tmp_html="$(mktemp --suffix=.html)"

	echo "INFO: Converting $md_file -> $out_file"

	if ! pandoc_output=$(pandoc "$md_file" \
		--from=gfm \
		--to=html5 \
		--wrap=none \
		--no-highlight \
		--resource-path="$(dirname "$md_file")" \
		-o "$tmp_html" 2>&1); then
		echo "$pandoc_output"
		echo "ERROR: pandoc failed to convert $md_file"
		rm -f "$tmp_html"
		exit 1
	fi
	echo "$pandoc_output" | grep -v "Defaulting to .* as the title\|To specify a title," || true

	# Confluence Storage Format has no native checkbox input element; use the
	# same ballot-box characters pandoc's own gfm writer recognizes as GFM
	# task-list markers, so confluence-to-md.sh can convert them straight
	# back into "- [x]" / "- [ ]" syntax.
	sed -i \
		-e 's/<input type="checkbox" checked="" \/>/☒ /g' \
		-e 's/<input type="checkbox" \/>/☐ /g' \
		"$tmp_html"

	convert_code_blocks "$tmp_html" >"$out_file"
	rm -f "$tmp_html"
	echo "INFO: Wrote $out_file ($(du -h "$out_file" | cut -f1))"
done

# EOF
