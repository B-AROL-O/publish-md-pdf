#!/bin/bash
# ==========================================================
# Conversion module: Confluence Storage Format -> Markdown. The reverse of
# lib/convert-confluence.sh.
#
# Sourced by publish-md-pdf.sh; not meant to be run directly.
# ==========================================================

convert_md_init() {
	require_command pandoc "sudo apt-get install -y pandoc"
}

# Reverses convert_confluence_emit_macro()'s CDATA-split and entity escaping,
# then re-escapes the raw code text as HTML so pandoc's HTML reader turns it
# back into a real fenced code block.
convert_md_emit_code_block() {
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
# structured macro back into a plain <pre><code> block pandoc's HTML reader
# understands. Mirrors convert_confluence_code_blocks(): the opening tag and
# the first content line share a line, and the closing tags are appended
# directly to the last content line.
convert_md_restore_code_blocks() {
	local in_code=0 lang="" buf="" line rest

	while IFS='' read -r line || [ -n "$line" ]; do
		if [ "$in_code" -eq 0 ]; then
			if [[ "$line" =~ ^\<ac:structured-macro\ ac:name=\"code\"\ ac:schema-version=\"1\"\>(\<ac:parameter\ ac:name=\"language\"\>([^\<]*)\</ac:parameter\>)?\<ac:plain-text-body\>\<!\[CDATA\[(.*)$ ]]; then
				lang="${BASH_REMATCH[2]}"
				rest="${BASH_REMATCH[3]}"
				if [[ "$rest" == *"]]></ac:plain-text-body></ac:structured-macro>" ]]; then
					convert_md_emit_code_block "$lang" "${rest%]]></ac:plain-text-body></ac:structured-macro>}"
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
			convert_md_emit_code_block "$lang" "$buf"
			in_code=0
			buf=""
		else
			buf+=$'\n'"$line"
		fi
	done <"$1"
}

convert_md_file() {
	local confluence_file="$1" out_file="$2"
	local tmp_html pandoc_output
	tmp_html="$(mktemp --suffix=.html)"

	convert_md_restore_code_blocks "$confluence_file" >"$tmp_html"

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
}

# EOF
